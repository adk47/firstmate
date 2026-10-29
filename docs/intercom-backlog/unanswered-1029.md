# Who is waiting on us in Intercom: customer spoke last more than 48 h ago (2026-10-29)

**Owner:** intercom-backlog-i1. **Asked by:** captain, 21:3xZ ("are we handling every person waiting on
us - are they being properly communicated with in Intercom?").

**The honest answer is no.** Nothing was sent or closed tonight, because no non-credit bucket has
approved wording (section 3).

**How this was measured (read-only):** a fresh census at 21:32Z on node-8 found 5,639 open
conversations, 1,936 of them customer-last and **1,876 past 48 h**. Each was bucketed on the customer's
LAST messages, read on node-8; no text left the host. The first message is often only a Messenger
button ("Issue with my profile", "Another question"), so it was not used. "paid" = member of a team
with an active or trialing subscription. Ids per bucket: `unanswered-1029-ids.md` (same folder).

**Almost all of this is old.** Of the 1,876, only about 145 are 30 days old or younger; the oldest
is 210 days.

## 1. Buckets, largest first (paid in brackets)

| bucket | total (paid) | ≤ 30 d | what it is | owner / route |
|---|---|---|---|---|
| credit / claim / merge by topic | 648 (204) | 84 | already owned by l1 via `reply_due` (the 441 + the rest of l1's classes) | verify-program-lead-fable-l1 |
| credit-like by last message | 272 (83) | 6 | asks about credits, songs, proof or verification; the first message was a button | **propose to l1** (credit-family); i1 keeps them until l1 takes them |
| merge-like | 47 (10) | 0 | duplicate profiles, merge asks | propose to l1 (merge rules) |
| removal-like | 32 (3) | 5 | "remove credits that are not me" | propose to l1 (removal = live Spotify + Tidal rule) |
| thanks-only | 193 (55) | 18 | the customer's last word is "thanks" / "ok" / an emoji: nothing is owed | silent close (c3's satisfied-close path) |
| other | 199 (49) | 20 | mixed, needs reading | i1 reads, paid first |
| no-detail | 104 (31) | 0 | the customer never said what they need: only a button, a greeting, or just an email address after we asked for it | needs one new line (draft A) |
| social-noise | 74 (0) | 0 | Instagram story mentions, shared posts, spam or ads | silent close, not a request |
| stats | 62 (25) | 0 | analytics missing or wrong | new line (draft B) |
| plaque-order | 53 (18) | 3 | where to order, order status, address | new line (draft C) |
| subscription | 37 (13) | 0 | manage, upgrade or which plan | new line (draft D) |
| billing-cancel | 36 (5) | 0 | how to cancel | new line (draft E) |
| billing-money | 30 (7) | 2 | refunds, charges | **captain** (money) |
| howto | 24 (5) | 0 | how-to questions | new line (draft F) |
| escalation | 21 (6) | 2 | angry or "talk to a human" | new line (draft G); captain sees the list |
| profile-edit | 14 (3) | 0 | rename, photo, bio | new line (draft H) |
| account-access | 10 (2) | 1 | login, password | new line (draft I) |
| auto-noise | 7 (0) | 1 | auto-replies, bounces | silent close |
| business | 6 (1) | 0 | partnership, API, sales | captain / sales list |
| legal | 4 (0) | 2 | legal threat or privacy | **captain / counsel** (aggressive-legal rule) |
| account-email | 2 (0) | 0 | change sign-in email | existing email-change path (copy approved, action first) |
| account-delete | 1 (0) | 1 | delete my account | privacy procedure (captain) |

**Total:** 1,876 (520 paid). By owner:
- **l1, already owned:** 648.
- **Proposed to l1:** 351 (credit-like + merge-like + removal-like).
- **i1:** the remaining 877.

The keyword buckets are rough. "credit-like" catches any message mentioning a song or a release, so l1
should expect some that are not credit asks.

## 2. Buckets Caroline can answer with already-approved copy today

**None of the non-credit buckets.** Here is what exists and why it does not fit:

- **Fixed approved copy** is all credit or claim status (the `intercom-verify-request.sh` campaigns, l1's).
  The other approved lines confirm an action already taken: withdrawal-confirm, email-changed, and the
  plaque round-milestone line. None answers an open question.
- **Caroline's FAQ** (`workspaces/support/reference/faq.md`) has true, reviewed answers for most of
  these topics. She uses it when a customer writes in live, but **there is no path that makes her answer
  an old thread**, and an old thread needs an opener that admits the delay. That opener is new copy, and
  the captain's 10-26 order says no new customer copy.
- **Two buckets need no copy at all:** thanks-only (193) and social-noise + auto-noise (81). The right
  action is a silent close with no message; a reply reopens the thread. Fable already approved this
  action for satisfied threads (`[key=intercom-close-satisfied]`, c3's batch 1: 8 closed after an
  eye-check). Extending it to these 274 is one decision (section 4, D1).

So **nothing was sent tonight and nothing went to proof-loop-lead-fable-p1**. "First 20 for an outcome
read" starts with the first approved bucket.

## 3. New lines to approve (short, plain, no promised action, no dates, no reasons on declines)

The same opener goes on every line: "Hi {first name}, sorry for the slow reply." For an unknown name it
is "Hi there". Every line ends with the same closer: "If you still need help, just reply here."

| | bucket | line (between opener and closer) | source of truth |
|---|---|---|---|
| A | no-detail (104) | "What can we help you with? Tell us in a few words, and add the link to your Muso profile if it's about your profile." | none needed |
| B | stats (62) | "Analytics show for profiles on an active Pro or Business plan with a seat assigned to the profile. You can check both in Settings. If they're set and your numbers still look wrong, reply with your profile link and the platform." | FAQ "Why are my analytics not showing?" |
| C | plaque-order (53) | "You can order a plaque on the Muso website at muso.ai/amp/promote/plaque (signed in), or in the Muso mobile app: open the Analytics tab and tap Plaque. If you already ordered, reply with your order ID and we'll look it up." | firstmate 10-29 21:46Z: the web also orders (web-credits-next `amp/promote/plaque`, the URL the Encore 26 emails use; it is sign-in gated, so 404 when anonymous). FAQ "Where do I order a plaque?" is out of date on this |
| D | subscription (37) | "You can see and change your plan in Settings in your account. Upgrades take effect right away." | FAQ "How do I upgrade my plan?" |
| E | billing-cancel (36) | "You can cancel in Settings. You keep access until the end of the billing period, and your credits and profile stay." | FAQ "How do I cancel my subscription?" |
| F | howto (24) | "Most answers are in our help center at help.muso.ai. If yours isn't there, reply with your question." | FAQ "Contact and Support" lists help.muso.ai as the knowledge base (it answered HTTP 200 at 21:5xZ) |
| G | escalation (21) | "You're talking with our support team here. Tell us what you still need and we'll pick it up from this thread." | none needed |
| H | profile-edit (14) | "You can edit your profile on app.muso.ai. If the name can't be changed there, reply with your profile link and the name you want." | FAQ "How do I update my profile information?" |
| I | account-access (10) | "Use 'Forgot password' on the login page, or sign in the way you signed up (Google or Apple). If that doesn't work, reply with the email you use for Muso." | FAQ "I can't log in" |

**Never in these lines:** "we fixed", "we updated", "your request is processed", dates, or why something
was declined.

The **billing-money (30), legal (4), account-delete (1) and business (6)** buckets get no line from
this lane; they go to the captain's list.

## 4. Decisions asked (one yes/no each), then the dated drain plan

- **D1:** silent close of thanks-only (193), social-noise (74) and auto-noise (7). No message; a
  customer reply reopens the thread. Fable eye-checks a random 20 first.
- **D2:** approve lines A-I, each yes or no. Each approved line opens only its own bucket.
- **D3:** l1 takes the 351 credit-like, merge-like and removal-like conversations, or tells i1 which to keep.

| when (UTC) | step | count |
|---|---|---|
| 10-29 23:30 | this report | - |
| 10-30 on D1 | silent close via the satisfied-close closer (c3's tool, shadow-logged, reversible by a reply), 50 first, then the rest after Fable's eye-check | 274 |
| 10-30 on D2 | DONE 10-29: `send.py --band bucket --bucket <name>` maps the nine buckets to lines A-I (PR https://github.com/Muso-AI/hydra/pull/1379), each line locked on its own; a one-line PR adds each approved line's ref to `BUCKET_APPROVED` | - |
| 10-30, after deploy | first 20 sends (paid, oldest), through the gated path (`intercom-ops-write.sh` + the shared ledger: one message per user per day, a live re-read of each thread before sending), to proof-loop-lead-fable-p1 for an outcome read | 20 |
| 10-31 | on a clean read: paid first, then free, oldest first, ≤ 200 per day | about 440 |
| 10-31 | i1 reads the "other" bucket (199) by hand and moves each conversation into a bucket or the captain list | 199 |
| 11-01 | the remainder: re-census, a new count line, and anything new past 48 h gets bucketed the same day | - |

**Rules that hold throughout:**
- one answer per thread and one message per user per day (shared ledger);
- never claim an action we did not take;
- no reasons on declines;
- no human sends;
- money, legal and privacy go to the captain.

## Update 10-29 ~22:1xZ

- **D3:** decided. l1 takes the 351; the ids are in `handoff-l1-351.md` (same folder).
- **D1 and D2:** with the captain.
- **Sender:** the bucket-to-line map is built and locked (every line locked until approved). The data
  feed is `buckets.py --out`, a 0600 file on node-8.
