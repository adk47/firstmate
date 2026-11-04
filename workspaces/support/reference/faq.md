# Frequently Asked Questions
<!-- Reviewed baseline: deploy overwrites the live copy of this file. The live edits of 2026-10-15/16 (section 8b sign-out workaround; plaque ordering) are folded in here together with PR #1224, so overwriting loses nothing. Drop this line once the next release has shipped (MUS-13058). -->

## Account and Profile

### How do I create an account?
Visit app.muso.ai and sign up with your email. The Lite plan is free forever.

### How do I claim my profile?
1. Search for your name at app.muso.ai
2. When you find your profile, click "Claim" and send the claim

<!-- approved: caroline-instructions-1029 §2.3 -->
Claims are confirmed by something only the profile's owner can do, so nobody can claim a profile that isn't theirs. After you claim, you get a message telling you the one thing to do, for example placing a short code on a page you control, and once we see it the claim is approved automatically, usually within a day. If that isn't possible for you, the same message tells you what paperwork works instead. We never ask for ID.

**"Is the code on one page enough?"** (they placed the code and ask whether it covers every platform or profile link):
<!-- approved: cs-health-1101 action 5 (c) -->
Yes, the code on one page you control is enough.

(Agent note: Caroline never issues a code, never names a surface for one and never reads a claim's state; the claim lane sends that message. The one-page line answers only the "is one enough / do I need it everywhere" question; it never says the claim went through. A claim that was closed: answer with the decline paragraph in `credits-and-profiles.md`, "A declined request". Anything about THEIR claim: `verification-handoff`.)

### Can I merge duplicate profiles?
<!-- approved: caroline-instructions-1029 §2.4 -->
Merges work like this: claim every profile that is yours first (so we know they're all you), then tell me which one should be the main profile. The merge is done by our verification team and you get a message in this conversation when it's complete; credits from the duplicates move onto the main profile. Profiles claimed by someone else, and company or label profiles, are handled differently: I'll pass those on.

(Agent note: Caroline files the `profile-merge` hand-off ticket per `verification-handoff`; she never merges and never says "I will merge".)

### How do I become an Album Admin?
Verified artists can become Album Admins, giving them control over the credits displayed for their albums and tracks. You must first verify your artist profile.

### How do I update my profile information?
Log in at app.muso.ai and edit your profile page directly. If the profile name cannot be changed in the editor, contact support with the claimed Muso profile link, the current name, and the requested professional name. Support may ask for artist-link or identity verification before making the change.

### How do I change my account email?
Contact support with the claimed Muso profile link and the new email address. If you cannot access the old email, support may ask for additional ownership verification before updating account access.

### Can I delete my profile?
Use the GDPR acknowledgement in `gdpr-erasure-requests.md` ("Approved acknowledgement"), verbatim, and file `data-deletion`. Never a business-day number, never "deleted".

---

## Credits

### How do I add a missing credit?
**No profile yet** (they want to add a first credit and have no Muso profile, or can't see "Add Missing Credits" / "Add Credits" because of that):
<!-- approved: cs-health-1101 action 5 (b) -->
You need a Muso profile before you can add a credit: claim or create your profile first, then add the credit.

(Agent note: then the claim how-to above, "How do I claim my profile?", if they ask how. Never the credit-process paragraph to someone who has no profile yet.)

1. Log in to your account
2. Web: open your profile and click "Add Credits" at the top right of the Summary panel, then search for the track or paste its Spotify link. App: open the track or album and tap "Add Missing Credits"
3. Specify your role (producer, songwriter, engineer, etc.)
4. Submit the claim with proof that connects you to that role

**Before submitting, check:**
- Is the track on Spotify? If it isn't (e.g. a YouTube- or Instagram-only release or a live session video), we can't add the track or its credits for now, so there is nothing to submit yet (agent note: say so plainly, don't promise a review – see credits-and-profiles.md)
- Is this a Muso-sourced credit or does it come from an external platform?
- If external (e.g. a Spotify or distributor feed), you need to fix it at the source first (see below)
- Useful proof includes official credits, distributor metadata, PRO registrations, split sheets, session screenshots, invoices, contracts, or collaborator confirmation

### My credit is incorrect. How do I fix it?

**If the credit was added through Muso.AI:**
- Ask in support chat; you'll hear in this conversation and by email

**If the credit comes from an external source (Spotify, distributor, label):**
- Muso reflects what those sources report – we can't override them directly
- Contact your distributor or the platform where the error originated
- Ask them to correct the metadata
- Once the source is fixed, Muso will automatically reflect the updated credit (typically within the next data sync)

**If you're unsure of the source:**
- Check whether the credit appears on the external platform as-is
- If it does, the fix must happen there first
- If it doesn't appear externally but shows incorrectly on Muso, create a support ticket with category "Credit Error – Muso Source"

### Why are some of my credits missing?
Credits come from multiple industry sources. A missing credit usually means one of:
- It hasn't been ingested from that source yet
- The source doesn't have it in their database
- There's a name/ISRC mismatch preventing the link

Try adding it manually: on web via "Add Credits" in your profile's Summary panel, in the app via "Add Missing Credits" on the track or album. If you believe it should be automatically sourced and it's not appearing, create a support ticket with category "Missing Credit – Source Discrepancy."

### How long does credit verification take?
<!-- approved: caroline-instructions-1029 §2.1 -->
Here is how credit requests work now: when you add a credit, we check it automatically against public credit sources. If we can confirm it, it goes live on your profile and you get an email. If we can't confirm it on our own, we message you, here and by email, and tell you exactly what would settle it. Documents that come from outside Muso are what we can use: a distributor or label statement, a split sheet, a contract, an invoice, a PRO registration. Where a document names a company, we may confirm it with that company directly. You hear the outcome in this conversation and on your request page.

(Agent note: no day count and no business days: "you'll hear in this conversation and by email". Caroline never asks for proof herself; for THEIR credit, `verification-handoff`. Never tell a customer their credit was flagged, held or doubted.)

### What credit roles are supported?
We support all standard music industry roles: Artist, Featured Artist, Producer, Executive Producer, Co-Producer, Writer, Composer, Lyricist, Mixing Engineer, Mastering Engineer, Recording Engineer, A&R, Creative Director, and more.

### How are credits shared with industry partners?
Credits edited through Muso.AI are automatically shared with our partners including Music Story, Airgigs, and Campsite.

---

## Analytics

### Which platforms does Muso track?
Analytics cover 7 platforms: Spotify, YouTube, YouTube Music, Shazam,
TikTok, SoundCloud, and Instagram.

### How often is analytics data updated?
Analytics run on our upgraded platform. Refresh cadence varies by platform and
data source. If your data looks stale, see "Why are my analytics not showing?"
below.

### Why are my analytics not showing?
Analytics require an active Pro or Business subscription with an available seat assigned to your profile.

**Check the following in order:**
1. Is your subscription active? Go to Settings and confirm your plan shows Pro or Business
2. Does your profile have a seat assigned? Check under your subscription settings

If subscription and seat are both fine and data still isn't showing,
reach out to support and we'll take a closer look at your specific profile.
Your data is being tracked in the background, and we can flag your profile
for our team to review.

### What are Milestones?
Milestones are streaming achievement thresholds: 10K, 100K, 1M, 10M, 100M, and 1B streams. They help you track career progress.

### Can I see analytics for someone else's profile?
You can view public profile data for any profile. Detailed analytics require the profile to be in your workspace with an available seat.

### Why don't I see Apple Music streams?
Apple Music isn't available in Muso analytics today. It's a known request,
but there's no committed date.

### My Spotify numbers don't match Muso's numbers – why?
Streaming numbers come from each platform on its own schedule, so some
difference between Muso and what you see on Spotify can persist because
each platform's attribution and reporting works differently. If the gap
still looks wrong, reach out and we'll check what your profile is showing
and flag it for our team if something's off.

---

## Catalog Audits

### What is a Catalog Audit?
Catalog Audits detect missing royalties by identifying unlinked recordings and unregistered works at the MLC (Mechanical Licensing Collective). They match ISRCs to ISWCs to find mismatches.

### How often are audits updated?
Audits are refreshed weekly with the latest MLC data.

### What do "Critical" and "Partial" issues mean?
- **Critical**: A recording is completely missing from the MLC -- you may be missing all mechanical royalties for that recording.
- **Partial**: A recording is registered but has incomplete or mismatched data -- some royalties may be affected.

### How do I fix audit issues?
The audit identifies the issues; resolution typically involves working with your distributor, publisher, or PRO to register or correct the works at the MLC.

---

## Developer / API Access

### How do I get API access?
If you're on Pro or Business, API access to your own workspace data is included. You generate your key in Settings, under the API access section – request a key there and it's issued to you. On the free Lite plan, you'd upgrade to Pro or Business first. It's a newer feature still rolling out, so if you're on a paid plan and can't find it, let me know and I'll get the team on it.

### Is API access free?
Workspace-level API access – your own workspace's data – is included at no extra cost on Pro and Business. Full-catalog access, meaning data across the whole Muso catalog beyond your workspace, is our developer platform at platform.muso.ai, which is paid and self-service. Let me know what you're building and I can point you to the right one.

### Can I pull data for the whole catalog, not just my workspace?
Yes – that's our developer platform at platform.muso.ai, which is separate from the workspace key included with your plan. It's self-service: you sign up, add a card and generate your own key, and it covers the full catalog – credits, profiles and analytics. Docs are at platform.muso.ai/docs. If you need custom volume or enterprise terms, let me know and the team will get you set up.

---

## Subscriptions and Billing

### What's the difference between Lite, Pro, and Business?
- **Lite** (Free): Credit management, profile page, company page, notifications
- **Pro**: Everything in Lite + Analytics, Catalog Audits, Discography Playlists, Milestones
- **Business**: Everything in Pro + Company Analytics, List Analytics, Multi-User Workspace, Discovery Tools

(For prices, retrieve `app-pricing.md` and quote the table matching the customer's billing cadence.)

### Can I try Pro for free? / Is there a free trial?
There's no free trial – Muso doesn't offer one. The way to use Muso at no cost is
the Lite plan, which is free forever: full credit management (claim your profile,
add and correct credits, company page, notifications), no card required.
Analytics, Catalog Audits, and the rest of the Pro features aren't available on a
trial basis – you'd upgrade to a paid Pro or Business plan for those. Never point a
customer to "current trial offers" or suggest a trial might exist; if someone is
deciding whether Muso is worth it, say plainly there's no free trial, steer them to
the free Lite plan, and offer to walk through the features or help them judge
whether it fits their needs.

### How do I upgrade my plan?
Go to Settings in your account and select the plan you want. Upgrades take effect immediately.

### How do I cancel my subscription?
Go to Settings and select cancel. You retain access until the end of your billing period. Your credits and profile data are never deleted – those are free features.

### I was charged but my subscription shows inactive
This usually means a payment processing delay. First check:
1. Does your bank statement show the charge as settled (not pending)?
2. Is the email address on your Muso account the same one that received the payment receipt?

If both look correct and your subscription still shows inactive after 24 hours, create a support ticket with category "Billing – Charged but Inactive" and include your payment confirmation.

---

## Technical Issues

### The website is not loading
Try clearing your browser cache and cookies, then reload. If the issue persists, try a different browser. If it still doesn't work, create a support ticket.

### I can't log in to my account
1. Use the "Forgot Password" link on the login page to reset your password
2. Check that you're using the correct email address
3. If you signed up via social login (Google, etc.), try that method instead

If none of the above works, create a support ticket with category "Login – Account Access."

### My streaming data seems incorrect
Streaming data comes directly from each platform, and differences
between platforms and Muso can persist because each one reports and
attributes on its own schedule. If it still looks off, message us back
and we'll re-check what your profile is showing and flag it for our
team if needed.

### The mobile app is not working
If the app shows "Error occurred. Try to reload", follow common-issues.md section 8b: tap the sign-out icon at the top right of the error screen, then sign back in. Updating or reinstalling the app is not the fix for that screen.

For other app problems: make sure you have the latest version from the App Store or Google Play. Try force-closing and reopening the app. If issues persist, create a support ticket.

---

## Platform Availability

- **Web**: app.muso.ai
- **iOS**: Available on the App Store
- **Android**: Available on Google Play

---

## Contact and Support

- **Website**: muso.ai
- **Support email**: support@muso.ai
- **Knowledge Base**: help.muso.ai
- **Developer Docs**: developer.muso.ai
- **Social**: Instagram, Facebook, Twitter/X, LinkedIn (search Muso.AI)

---

## Plaque orders

### Where do I order a plaque?
In the **Muso mobile app (iOS or Android)**: open the **Analytics** tab for the profile and tap
**Plaque**, or go to **Flex** and choose **Make it Official** or one of the milestone / track /
album plaque cards. Customise it there and check out. Plaque ordering is **not available on the
website** right now (do not send customers to app.muso.ai → Milestones; that button is hidden).
One-line answer: "You can order a plaque in the Muso mobile app (iOS or Android): open the
Analytics tab and tap Plaque, or go to Flex and choose Make it Official or one of your milestone
cards. Plaque ordering isn't available on the website right now, and it needs an active subscription
(Pro or Business)."

### Do I need a paid subscription to order a plaque?
Yes, today. In the app the plaque options are locked (they open the paywall) unless the workspace
has an active subscription and the selected seat is a profile (not a list). Managing your profile
and correcting credits stay free on Lite. (Corrected 2026-10-15: every paid plaque order in the
last 30 days came from a paid workspace.)

### My plaque shows old stream numbers – can it be updated?
If your plaque shows numbers that don't match what you'd expect, open a
ticket with the order ID and the team will sort it out.

### I need to fix / change the shipping address on my order
Share your order ID and the full corrected address – recipient name,
address line 1 (and line 2 if needed), postcode, city, state/province if
applicable, country, and a phone number. Keep each line fairly short (around
40 characters). Caroline flags it for the fulfillment team to update on the
order; if printing has already started it isn't guaranteed, but they'll try.
(Doctrine + the Prodigi format rules: `orders-and-fulfillment.md`.)

### Where is my plaque / can I get tracking?
Plaques are printed to order and then shipped, so allow time for both. For the
live status or a tracking link, share the order ID and Caroline flags it for
the fulfillment team. See `orders-and-fulfillment.md`.

---

## Profile management

### I don't have a paid plan – can I still fix wrong credits on my profile?
Yes. Adding, removing, and correcting credits is free. Subscriptions
unlock analytics and insights and are needed to order a plaque; basic
profile work like correcting credits is free. If
you're hitting a UI issue while editing, let me know and I'll open a ticket
so the team can look.
