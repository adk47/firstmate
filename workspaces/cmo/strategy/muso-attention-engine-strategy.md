# MUSO ATTENTION ENGINE — 3-Month Sprint Strategy

**Status:** DRAFT — For Aaron + Leadership Review
**Author:** CMO (HYDRA) with Fede
**Date:** April 16, 2026
**Classification:** YELLOW — Internal Leadership Only

---

## 1. Executive Summary

Muso has a credibility gap that will kill the ads business if we don't fix it. We pitch "500K+ verified music professionals" to advertisers, but our actual Monthly Active Users hover around 50K on a normal day. The moment a buyer asks for verified DAU, we're exposed. This strategy turns Muso from a credit database people check occasionally into a daily-use professional network — generating the genuine attention that makes ads work.

**The thesis in three sentences:**

1. Our engagement gap (large registered base, low daily activity) makes our ads pitch fragile and limits ad revenue potential.
2. By building an "Attention Engine" — Profile Views + Chat + Onboarding Fix — we create a LinkedIn-style daily engagement loop that brings users back every day.
3. With real daily active users, we can sell ads with honest, verifiable metrics that actually deliver for advertisers.

---

## 2. Current State Audit — Real Numbers

### 2.1 User Engagement (Amplitude)

| Metric | Value | Source |
|--------|-------|--------|
| Monthly Active Users (Apr '26 partial) | ~965K cumulative events / est. 50-70K true unique MAU | Amplitude |
| 30-Day Average DAU | 43,668 | Amplitude (Mar 18–Apr 16) |
| Median DAU | 24,610 | Amplitude (Mar 18–Apr 16) |
| DAU Range | 12,570 – 158,516 | Amplitude (spikes = email/campaign days) |
| Avg Session Length (7-day) | 45s (range: 19s–71s) | Amplitude |

**Key insight:** DAU is extremely spiky. On quiet days we drop to ~13K. On campaign/email days we spike to 65K–158K. There is no organic baseline of daily engagement — users come when we ping them and leave. This is the core problem.

**DAU/MAU ratio:** If we estimate true MAU at ~70K unique users and median DAU at ~25K, that's a ~35% DAU/MAU ratio on paper — but it's misleading because of extreme variance. The "quiet day" DAU of 12-15K against 70K MAU gives us a real engagement ratio closer to 17-20%. For comparison, LinkedIn runs ~40% DAU/MAU.

### 2.2 Subscribers (ChartMogul)

| Metric | Value | Trend |
|--------|-------|-------|
| Total Paying Customers | 14,194 | Down from 17,468 peak (Dec '25 Encore) |
| MRR | $192,108 | Stable — recovered from Jan churn wave |
| ARR | $2,305,298 | — |
| ARPA | $13.53/mo | Slowly increasing (was $12.29 Nov '25) |
| Customer Churn Rate (Apr) | 7.88% | Improving from 19.7% Jan post-Encore |
| LTV | $129.97 | Declining (was $195 Nov '25) — concerning |

**Revenue trajectory:**
- Nov '25: $153K MRR (12,453 customers)
- Dec '25: $217K MRR (17,468 customers) ← Encore peak
- Jan '26: $193K MRR (15,389) ← 19.7% churn wave
- Feb '26: $184K MRR (14,582)
- Mar '26: $193K MRR (14,267)
- Apr '26: $192K MRR (14,194) ← today

MRR has stabilized but we've lost 3,274 subscribers since Encore peak. LTV declining from $195 to $130 is a red flag — we're acquiring but not retaining long enough.

### 2.3 Email List (Klaviyo)

| Segment | Size |
|---------|------|
| Master Email List | 367,191 |
| Lite Members (Never Had Pro) | 314,285 |
| Pro Plan (trial + paid) | 12,633 |
| Business Plan (trial + paid) | 1,104 |

**The gold:** 314K Lite members who've never paid. This is the conversion pool for Profile Views paywall.

### 2.4 Profile View Email — Proof of Concept

This is the most important data point in this entire strategy. In Dec '25, we A/B tested two Lite→Pro acquisition angles:

| Campaign | Recipients | Open Rate | Click Rate | Clicks |
|----------|-----------|-----------|------------|--------|
| **Angle A: Profile View** (#1 — Lite sample) | 14,059 | **77.5%** | **10.5%** | 2,203 |
| **Angle A: Profile View** (#2 — Broader list) | 78,958 | **78.8%** | **11.0%** | 12,794 |
| Angle B: Encore Offer (control) | 12,859 | 59.4% | 1.6% | 347 |

**Profile View emails outperformed the Encore offer by 6.8x on click rate.** Nearly 79% of recipients opened the email. 11% clicked through. These are not normal email numbers — industry average is 21% open, 2.6% click. Our Profile View angle is 3.7x industry on opens and 4.2x on clicks.

This is the proof of concept. People desperately want to know who's looking at their profile.

### 2.5 Ad Performance (AMP Reports — Latest)

From the Apr 16 daily report:

| Metric | All-Time | 7-Day | Today (partial) |
|--------|----------|-------|-----------------|
| Views | 248,128 | 33,799 | 1,485 |
| Clicks | 1,962 | 203 | 8 |
| CTR | 0.79% | 0.60% | 0.54% |
| Unique Viewers | 23,749 | 7,217 | 463 |

**Platform breakdown (7d):**
- iOS: 15,508 views / 0.77% CTR ← biggest volume
- Desktop Web: 14,167 views / 0.40% CTR
- Android: 2,305 views / 1.04% CTR ← highest engagement
- Mobile Web: 1,817 views / 0.17% CTR ← dead

**AMP vs Feed:** Feed CTR (0.70%) outperforms AMP (0.57%) by 23%, but AMP drives 85% of impressions.

**The problem visualized:** 7,217 unique ad viewers in a week. If we're pitching "reach 500K professionals" but only 7K people actually see the ads… that's a 1.4% delivery rate. Advertisers will eventually notice.

### 2.6 Profile Completion (from #growth-team discussion, Apr 14)

| Metric | Value |
|--------|-------|
| Pro subs with truly claimed profiles | 44% (~6,400) |
| Pro subs with only auto-created profiles | 56% (~8,000) |
| Older cohorts (3+ months) claimed rate | 70-83% |
| New cohorts (Mar/Apr '26) claimed rate | 15-22% |

**Massive onboarding gap:** 8,000 paying Pro subscribers have never properly set up their profile. New cohorts are even worse — only 15-22% claim in their first months. This means Profile Views launches to a world where over half the Pro base has blank/auto-created profiles that nobody wants to view.

---

## 3. Phase 1 (Month 1): The Hook — Profile Views + Chat + Onboarding Fix

### 3.1 Profile Views

**What:** LinkedIn-style "See who viewed your profile" feature with notifications via email, push, and in-app.

**How it works:**
- Backend tracks profile views using identity resolution via `findPrimary()` (ADR-029, already in implementation)
- Stores both `userId` and `profileId` in PG table with daily dedup
- Fire-and-forget write, Knock batching for notifications
- Daily/weekly email: "X people viewed your profile this week. See who →"

**Premium gating (the conversion engine):**
- **Free/Lite users:** See that X people viewed their profile. See top 3 viewers by popularity score. Rest blurred behind Pro paywall.
- **Pro users:** See full list of who viewed them.
- This is both engagement (daily reason to open the app) AND monetization (FOMO drives Lite→Pro).

**DAU impact model (using real Klaviyo data):**

| Scenario | Assumption | Daily New Sessions |
|----------|------------|-------------------|
| Conservative | 5% of Master List (367K) clicks daily notification | +18,350 |
| Moderate | 8% click-through (our test showed 11%) | +29,375 |
| Aggressive | 11% (matching our test CTR) | +40,391 |

Even the conservative scenario nearly doubles our quiet-day DAU (12-15K → 30K+). The moderate scenario would put us at 50-55K baseline DAU — a transformative shift.

**Backtracking opportunity (per Fede's ask):** If we can backfill historical profile views from existing server logs/analytics events, we launch with every user already having a populated "who viewed you" history. Day 1 engagement instead of waiting for views to accumulate.

**Status:** ADR-029 approved, Ihor has started implementation scaffolding, Mariia has completed LinkedIn UX analysis and Figma brainstorming board, Notion spec created ("Profile Views — Scope: MVP vs Full").

**Timeline:** 3-4 weeks to MVP.

### 3.2 Chat

**What:** In-app messaging between music professionals. The critical missing piece that turns a view into a connection.

**Why it must ship with Profile Views:**
The LinkedIn flow: notification ("someone viewed you") → open app → see who → look at their profile → **message them** → conversation → daily habit. Without chat, the loop breaks at step 5. The user sees who viewed them, maybe views them back, and... that's it. No action to take. No relationship formed. No reason to come back tomorrow.

**MVP scope:**
- Direct messaging between any two users (no connection request gatekeeping — music industry is collaborative, not gated)
- Message from profile page: "Send a message" button
- In-app notification + push notification for new messages
- Unread message count on nav
- Message history / conversation threads

**Full scope (Month 2-3):**
- Read receipts
- File/media sharing (send a track, a mix, a reference)
- Group conversations
- Message requests (optional privacy layer)

**The unique angle:** Nobody else offers verified music professionals a way to connect based on real credits and catalog data. On LinkedIn, you message someone because of their job title. On Muso, you message someone because they worked on a specific record. That's 10x more targeted and 10x more valuable.

**Aaron's vision (from #growth-team, Apr 16):** "Maybe we have some sort of feature for people that do sync / music coordinators (buyers for commercials or TV shows or movies) can reach out to users on muso if they like their tracks for purchase." This is the eventual endgame — Muso Chat becomes where business happens in music. Sync deals, session bookings, mix requests.

**Timeline:** 4-6 weeks for MVP. Must overlap with Profile Views development — they ship together or close together.

### 3.3 Onboarding Fix

**What:** Mandatory profile completion flow that ensures every new user has a real, viewable, useful profile.

**Why this is the foundation:**
- Profile Views with blank profiles = "12 people viewed your profile" → click → see 12 grey avatars with no names → useless → never come back
- Chat with blank profiles = nobody messages a blank profile → feature goes unused
- Ad targeting with empty role/genre data = can't segment, can't target → ads underperform

**Current state (from Amplitude/team data):**
- 56% of Pro subscribers only have auto-created profiles (no photo, no bio, no verified social)
- New cohorts: 78-85% never properly set up their profile in the first month
- Signup flow doesn't enforce: full name, role, photo, genre, social connections

**Required onboarding flow:**
1. Full name (mandatory)
2. Primary role in music: artist, songwriter, producer, engineer, manager, label, publisher, sync, etc. (mandatory — this feeds ad targeting)
3. Primary genre(s) (mandatory — feeds discovery + ad targeting)
4. Profile photo (mandatory — critical for Profile Views credibility)
5. Connect Spotify / Apple Music / catalog (recommended but skippable)
6. Connect social (recommended but skippable)

**Existing user re-engagement:**
- For the 8,000+ Pro subs with incomplete profiles: "Complete your profile to see who's been viewing you" campaign
- Gate Profile Views behind minimum profile completion (name + role + photo)
- Amplitude data needed: exact funnel from signup → profile completion. What % complete each step? Where's the biggest drop?

**Timeline:** 2-3 weeks. Must ship BEFORE or simultaneously with Profile Views.

---

## 4. Phase 2 (Month 2): The Push — Acquisition Campaign

### 4.1 Paid Acquisition

**Messaging pivot:**
- **Old:** "Track your credits and streaming data" (utility)
- **New:** "The professional network for music. See who's watching your career. Connect with collaborators. Grow." (emotion + social proof)

This isn't just a tagline change — it's a product positioning shift. We're moving from "database tool" to "professional network." That changes every touchpoint: ads, landing pages, onboarding, App Store listing, everything.

**Facebook/Instagram Campaign:**
- Target: music professionals 22-45, interests in DAWs (Logic, Ableton, Pro Tools), music production, audio engineering, music business
- Lookalike audiences based on existing Pro subscribers
- Creative direction: NOT corporate SaaS ads. Think about what stops a producer scrolling Instagram at 2am:
  - "327 people viewed your credits this month. Who are they?" (curiosity)
  - Short video: someone opening Muso, seeing a profile view from a Grammy-winning engineer, messaging them (aspiration)
  - Carousel: real Muso profiles of recognizable music professionals (social proof)

**Budget model:**

| Metric | Conservative | Moderate | Aggressive |
|--------|-------------|----------|------------|
| Monthly Budget | $15,000 | $30,000 | $50,000 |
| Estimated CPA (music vertical) | $8-12 | $6-10 | $5-8 |
| New Signups/Month | 1,250-1,875 | 3,000-5,000 | 6,250-10,000 |
| Pro Conversion (5% est.) | 63-94 | 150-250 | 313-500 |

Music vertical CPAs tend to run higher than general SaaS ($3-5). Estimate $6-12 for a qualified signup based on comparable platforms (Splice, LANDR, DistroKid ad benchmarks).

**Note:** Budget requires Aaron's approval. Any spend >$30 goes through him.

### 4.2 Organic + Viral

**Influencer Seeding Strategy:**

We have the data to make this surgical. Pull claimed profiles with highest popularity scores — these are real, verified music professionals already on Muso. Send them custom plaques + early access to Profile Views + Chat.

Target list construction:
- 20-30 high-popularity claimed profiles across genres
- Mix of: A-list (2-3 for aspirational value), B-list (5-10 for relatability), rising stars (10-15 for shareability)
- Focus on producers and engineers — they're the most active community and the most likely to share on socials

Plaque cost: ~$50-80 per custom plaque + shipping = ~$1,500-2,400 for 30 units.

**Viral Video Concepts:**

1. **"Your Profile Is Being Watched"** — Screen recording style. Someone opens Muso, sees profile view notification. Clicks through. Sees a major artist viewed their profile. Texts their friend. Cut to: their friend seeing the same thing. The implication: everyone in music is already on here, you just didn't know.

2. **"The DM That Changed Everything"** — Narrative style. A bedroom producer gets a Muso chat message from a label A&R: "Loved the guitar work on [track]. Got a sync opportunity." Shows the message, the conversation, the deal happening. Tagline: "Connections happen when people can find you."

3. **"500,000 Music Professionals. One Platform."** — Fast montage of real Muso profiles — diverse genres, roles, countries. Credits rolling like end credits on a film. Ends with: "Who's looking at yours?"

### 4.3 Email Blasts

**Full Klaviyo List Activation:**

| Segment | Size | Message |
|---------|------|---------|
| Hot — Active Pro (opened email last 30d) | ~5,000 | "Profile Views is live. Chat is live. See who's been looking → [CTA]" |
| Warm — Active Lite (opened last 30d) | ~40,000 | "327 people viewed your profile this month. Upgrade to see who → [CTA]" |
| Cool — Inactive Lite (no open 30-90d) | ~100,000 | "Muso just changed. It's now where music professionals connect. Come back → [CTA]" |
| Cold — Dormant (90d+ inactive) | ~170,000 | "We rebuilt Muso. Here's what you missed → [CTA]" |

**Projected delivery based on our benchmarks:**
- Our open rates: 60-70% (proven across campaigns)
- Profile View angle: 78-79% open rate, 11% CTR (proven in Dec '25 test)
- Conservative: 50% open, 8% CTR on reactivation emails to the full list
- That's ~146K opens, ~29K clicks from one blast to the Master List

### 4.4 Messaging — Through the Humanizer

All external copy must go through the humanizer skill. Core principles:
- No AI filler, no corporate speak, no "unlock the power of"
- Write like a real person in music would talk
- Test: "Would a producer screenshot this and share it?" If no, rewrite.

---

## 5. Phase 3 (Month 3): The Sell — Muso Ads at Scale

### 5.1 From Vanity Metrics to Real Metrics

After 2 months of Profile Views + Chat, we'll have real engagement data to sell:

**Current ad pitch (fragile):**
- "500K+ verified music professionals"
- "Targeted by role, genre, geography"
- (Advertiser asks: "How many of them are actually active?" We deflect.)

**New ad pitch (bulletproof):**
- "X daily active professionals (verified, not bots)"
- "Y average minutes per session"
- "Z% of users engage with ads weekly"
- "W average profile views per user per day (attention = eyeballs on content)"
- "Case study: [Client] saw N% CTR, M conversions in 30 days"

### 5.2 Projected Metrics with 2-3x DAU

| Metric | Current (Baseline) | Projected (2x DAU) | Projected (3x DAU) |
|--------|-------------------|--------------------|--------------------|
| DAU (quiet day) | ~13K | ~26K | ~39K |
| DAU (avg) | ~44K | ~88K | ~132K |
| Weekly Ad Impressions | ~34K | ~68K | ~102K |
| Weekly Ad Clicks | ~200 | ~400 | ~600 |
| Weekly Unique Ad Viewers | ~7.2K | ~14.4K | ~21.6K |
| Weekly Ad CTR | 0.60% | 0.60-0.80%* | 0.60-0.90%* |

*CTR likely improves with better-targeted users from onboarding data + engaged users from Profile Views/Chat (engaged users click more).

### 5.3 B2B Outreach Refresh

Update the entire outreach engine with new messaging:
- Move from "reach 500K profiles" to "reach X daily active professionals spending Y minutes per session"
- Add case studies: MWTM ($6,127.80/mo), SSL, Casio — real results
- Include engagement metrics dashboard screenshot in pitch deck
- Run the updated pitch through the full B2B prospect pipeline

### 5.4 Advertiser Campaign

- Dedicated landing page: "Advertise on Muso" with real-time engagement metrics
- Case study PDFs from existing ad partners
- Direct outreach to warm pipeline (GHL B2B-Ads-Clio)
- Targeted approach to sync/licensing companies (Aaron's vision — they want to reach artists directly)

---

## 6. KPI Dashboard — Targets Per Phase

### Phase 1 Targets (Month 1)

| KPI | Current | Target | How We Measure |
|-----|---------|--------|----------------|
| DAU (quiet day) | ~13K | 25K+ | Amplitude |
| DAU (average) | ~44K | 60K+ | Amplitude |
| Profile completion rate (new signups) | 15-22% | 80%+ | Amplitude funnel |
| Pro subs with complete profiles | 44% | 60%+ | Amplitude |
| Profile Views email open rate | 78.8% (test) | 70%+ (at scale) | Klaviyo |
| Profile Views email CTR | 11% (test) | 8%+ (at scale) | Klaviyo |
| Pro conversions from Profile Views paywall | — | 200+/month | Stripe / ChartMogul |

### Phase 2 Targets (Month 2)

| KPI | Current | Target | How We Measure |
|-----|---------|--------|----------------|
| MAU | ~70K | 120K+ | Amplitude |
| DAU (average) | 60K | 80K+ | Amplitude |
| New signups/month | — | 5,000+ | Amplitude |
| Chat adoption (% DAU using chat weekly) | — | 15%+ | Amplitude |
| Paid CPA | — | <$10 | Meta Ads Manager |
| Email reactivation (dormant → active) | — | 10K+ reactivated | Klaviyo + Amplitude |

### Phase 3 Targets (Month 3)

| KPI | Current | Target | How We Measure |
|-----|---------|--------|----------------|
| MAU | 120K | 150-200K | Amplitude |
| DAU/MAU ratio | ~17-20% | 25%+ | Amplitude |
| Weekly ad impressions | 34K | 75K+ | AMP reports (Athena) |
| Weekly ad CTR | 0.60% | 0.75%+ | AMP reports |
| Weekly unique ad viewers | 7.2K | 15K+ | AMP reports |
| New B2B ad deals closed | — | 3-5 | GHL pipeline |
| MRR | $192K | $210K+ | ChartMogul |

---

## 7. Budget

| Item | Monthly Cost | 3-Month Total | Notes |
|------|-------------|---------------|-------|
| Paid Acquisition (Meta Ads) | $15-30K | $45-90K | Requires Aaron approval. Start conservative, scale on CPA. |
| Influencer Plaques (30 units) | — | $2,400 | One-time. $80/unit incl. shipping. |
| Video Production (3 concepts) | — | $5,000-15,000 | Range: DIY internal → professional. |
| Creative/Design | Internal | $0 | Mariia + existing design team. |
| Engineering | Internal | $0 | Ihor, Serhii, Nick — already allocated. |
| Klaviyo (increased sends) | Already paid | $0 | Existing plan covers volume. |
| **Total Range** | | **$52,400 – $107,400** | |

**Minimum viable budget:** $52,400 (conservative paid, DIY video, plaques).
**Recommended budget:** $75,000 (moderate paid, semi-pro video, plaques).
**Aggressive budget:** $107,400 (full paid push, professional video, plaques).

---

## 8. Risks — Brutally Honest

### 8.1 The 500K vs. 70K Credibility Gap
**Risk: HIGH.** This is a live grenade. If an advertiser audits our "500K+ professionals" claim against actual engagement data before we fix it, we lose credibility permanently. We need to either stop using the 500K number in pitches OR qualify it clearly ("500K registered profiles, XK monthly active"). The Attention Engine is the fix, but it takes 2-3 months to show results. In the interim, we're exposed.

**Mitigation:** Immediately shift B2B pitch language from "500K profiles" to "the largest verified database of music professionals" (true, not engagement-dependent). Once Phase 2 delivers, switch to active-user metrics.

### 8.2 Chat Could Flop If Profiles Are Empty
**Risk: HIGH.** Chat without completed profiles is like a dating app where everyone's anonymous. Nobody messages a blank profile. If onboarding doesn't fix the 56% empty-profile problem before Chat launches, adoption will be near-zero and we'll conclude "chat doesn't work for our users" when the real problem was empty profiles.

**Mitigation:** Ship onboarding fix BEFORE or alongside Chat. Gate Chat behind minimum profile completion (name + role + photo). Run re-engagement campaign for existing users with incomplete profiles.

### 8.3 Profile Views Chicken-and-Egg
**Risk: MEDIUM.** Profile Views only generates engagement if enough people are actually visiting profiles to create view data. If nobody's visiting profiles, there's nothing to notify about. This is the cold-start problem.

**Mitigation:** (a) Backfill historical view data from server logs if possible — launch with existing data, not from zero. (b) The Feed already drives profile visits (AMP ads, content) — ~34K profile views/week already happening. (c) Profile View notifications themselves drive profile visits, creating a flywheel: notification → visit → generates views → more notifications.

### 8.4 Paid Acquisition CPA Could Be Too High
**Risk: MEDIUM.** Music industry professionals are a niche audience. CPAs for niche B2C SaaS can run $15-25. If we're at $20/signup with a 5% Pro conversion rate, we're paying $400 per Pro subscriber who generates $13.53/mo ARPA with a $130 LTV. That math doesn't work.

**Mitigation:** Start with $15K/mo test budget. Kill the campaign fast if CPA > $12. Focus on retargeting existing Lite users (we have 314K emails — retargeting this warm audience should be much cheaper than cold acquisition). Organic/viral should handle the heavy lifting; paid is amplification, not the core engine.

### 8.5 Timeline Is Aggressive
**Risk: HIGH.** Profile Views (3-4 weeks) + Chat MVP (4-6 weeks) + Onboarding redesign (2-3 weeks) + Campaign creative + Influencer coordination — all in 3 months — is a lot. Engineering has other priorities (ADR-026 ad management, ADR-027 company associations, Turnstile, 2FA). Any of these could slip.

**Mitigation:** Phase 1 is the only must-ship-on-time phase. Profile Views + Onboarding should be prioritized above all other engineering work. Chat MVP can slip 2-3 weeks into Phase 2 without killing the strategy. Paid acquisition (Phase 2) doesn't need engineering — it can start as soon as positioning is ready. Phase 3 is contingent on Phase 1-2 results.

### 8.6 Retention Might Not Improve
**Risk: MEDIUM.** We can drive signups and DAU, but if the core product loop doesn't deliver value, people will churn just like they did post-Encore (19.7% in January). Profile Views and Chat create a reason to come back, but the underlying product still needs to be useful.

**Mitigation:** Monitor D7 and D30 retention by cohort aggressively. If Profile Views cohorts show <20% D30 retention, the product loop isn't working and we need to iterate before scaling acquisition.

---

## 9. Dependencies

### Engineering (Ihor, Serhii, Nick)

| Deliverable | Owner | Est. Effort | Must Ship By |
|-------------|-------|-------------|-------------|
| Profile Views MVP (ADR-029) | Ihor (started) | 3-4 weeks | End of Month 1 |
| Identity resolution for viewers | Ihor/Serhii | Included in ADR-029 | Month 1 |
| Notification system (Knock integration) | Ihor | 1 week | Month 1 |
| Chat MVP (messaging infrastructure) | TBD | 4-6 weeks | End of Month 1 / Early Month 2 |
| Onboarding flow redesign (backend) | TBD | 1-2 weeks | Month 1 (before PV launch) |
| Profile Views paywall gating | Ihor | 1 week | Month 1 |
| Historical view backfill | Serhii/Ihor | 1 week | Month 1 (nice-to-have) |
| Ad analytics dashboard for sales | Nick | 2 weeks | Month 3 |

### Design (Mariia)

| Deliverable | Status | Est. Effort | Must Ship By |
|-------------|--------|-------------|-------------|
| Profile Views UX (widgets, flows) | In progress (Figma board complete) | 2-3 weeks | Month 1 |
| Chat UX (messaging interface) | Not started | 2-3 weeks | Month 1 |
| Onboarding flow redesign (UX) | Not started | 1-2 weeks | Month 1 |
| Premium gating UI (blur + upgrade CTA) | Not started | 1 week | Month 1 |
| Profile Views notification templates | Not started | 1 week | Month 1 |

### Marketing (CMO / Fede)

| Deliverable | Owner | Est. Effort | Must Ship By |
|-------------|-------|-------------|-------------|
| Messaging pivot (copy + positioning) | CMO + Fede | 1 week | Month 1 |
| Klaviyo email templates (PV notifications) | CMO | 1 week | Month 1 |
| Influencer target list (high-pop profiles) | CMO | 2 days | Month 2 |
| Paid campaign creative | CMO + external | 2 weeks | Month 2 |
| Viral video concepts (3x) | CMO + Fede | 1 week | Month 2 |
| B2B pitch deck refresh | CMO | 1 week | Month 3 |
| Outreach engine update (new messaging) | CMO | 3 days | Month 3 |

### External / Aaron

| Dependency | Notes |
|------------|-------|
| Budget approval (>$30 per policy) | Paid media budget needs Aaron's explicit OK |
| Product prioritization call | Engineering needs to deprioritize other work for Phase 1 |
| B2B pitch approval | New messaging needs Aaron review before outreach |
| Advertiser case study permissions | Need MWTM, SSL, Casio OK to use their results |

---

## 10. The Honest Bottom Line

This strategy works if — and only if — Phase 1 ships on time and the engagement loop actually engages. The Profile View email test gives us strong evidence that it will (79% open rate doesn't lie). But email CTR and daily product habit are different things.

The 3-month timeline is tight but doable if engineering focuses. The biggest risk isn't any individual feature — it's trying to ship three interdependent features (Profile Views + Chat + Onboarding) simultaneously. If we have to choose, the priority order is:

1. **Onboarding fix** (foundation — everything else fails without it)
2. **Profile Views** (the hook — proven engagement driver)
3. **Chat** (the retention layer — can slip 2-3 weeks if needed)

If we execute this, we go from "credit database with an engagement problem" to "professional network with real daily users and honest ad metrics." That's not just a better ads business — it's a fundamentally different company.

---

---

## 11. Presentation Sequence — "The Muso Attention Engine"

### Visual Style Guide

| Element | Value |
|---------|-------|
| Background (primary) | #050505 |
| Background (cards) | #0D0D0D |
| Background (surfaces) | #171717 |
| Text (headings) | #FFFFFF |
| Text (body) | #FFFFFFA6 (white 65% opacity) |
| Accent (primary teal) | #05A38A |
| Accent (CTA/highlights) | #03C9A9 |
| Secondary (interactive) | #007AFF |
| Secondary (success) | #13CE66 |
| Font | Manrope (all text) |
| Vibe | Dark mode. Minimal. Music-tech. Spotify meets Bloomberg Terminal. |

### Sequence Structure

Each chapter is a self-contained segment that ends on a cliffhanger before the next one drops.

---

### Chapter 1: "The Invisible 95%"

**HOOK:**

95% of the people who make the music you love are invisible.

You know the artist. You stream them. You follow them. You know their name.

But you don't know the 47 people who built that sound.

The engineer who spent 14 hours getting the vocal chain right. The session guitarist who played the hook in one take. The mastering engineer who made it punch through your AirPods. The songwriter who wrote the bridge at 3am in a hotel room.

They don't have fan pages. They don't have millions of followers. Most of them don't even have a way to prove they worked on it — unless someone digs through liner notes that barely exist anymore.

This is the music industry's dirty secret: the people who actually make the music are the least visible people in it.

**CLIFFHANGER:**

"So someone built a platform to fix that. To give every person behind every song a verified, permanent record of their work. But then they realized fixing credits wasn't enough..."

---

### Chapter 2: "The Database Trap"

**HOOK:**

Muso has 29 million profiles. 500,000 verified music professionals. The largest verified credit database in the world.

But here's the problem nobody talks about:

It's a database.

People come, check their credits, maybe claim their profile, and leave. They come back when they have a new release. Or when someone asks "hey, are your credits on Muso?" They check. They confirm. They close the tab.

The data is incredible. The product is real. The credits are verified and permanent.

But the engagement pattern is: visit → check → leave → forget → maybe come back in 3 months.

That's not a platform. That's a reference tool. And you can't build a business on a reference tool — because nobody's paying attention long enough for anything else to work.

Not ads. Not networking. Not discovery. Nothing.

The data says it clearly:
- Average DAU on a quiet day: 12,570
- Median DAU: 24,610
- But on email campaign days: 65,000–158,000

Users come when we ping them. And leave when we stop.

**CLIFFHANGER:**

"People come, check their credits, and leave. What if they had a reason to come back every single day?"

---

### Chapter 3: "Who's Watching You?"

**HOOK:**

LinkedIn's most addictive feature isn't jobs. It isn't the feed. It isn't endorsements or recommendations or any of that.

It's five words:

*"47 people viewed your profile this week."*

That itch. That curiosity. Who are they? Why were they looking at me? Is it a recruiter? A competitor? An old colleague?

You click. You check. You come back the next day to see if the number went up. You look at who's viewing and you view them back. And suddenly you're on the platform every day, not because you need a job, but because you're curious.

Now imagine that for music.

A producer opens her phone and sees: "23 people viewed your profile this week. Including 3 A&R reps and an engineer who worked on [Album]." 

She clicks. She sees who. She views them back. She messages one of them.

That's not a credit lookup. That's a daily habit.

And nobody — nobody — is doing this for music professionals. Not Spotify for Artists. Not AllMusic. Not Discogs. Not SoundBetter. Nobody has a verified professional identity layer combined with a "who's watching you" mechanic.

Until now.

**CLIFFHANGER:**

"We tested it. The results were unlike anything we'd ever seen..."

---

### Chapter 4: "The Numbers"

**HOOK:**

In December 2025, we ran an A/B test. Two emails to our Lite user base.

**Email A:** The profile view angle — "People have been viewing your Muso profile. See who →"

**Email B:** Our strongest seasonal offer — the Encore campaign, discounts, urgency, limited time.

The Encore offer had always been our best performer. 59.4% open rate. 1.6% click rate. Good by any standard.

The profile view email?

**78.8% open rate. 11.0% click-through rate.**

Sent to 78,958 people. 12,794 of them clicked.

That's 6.8x the click rate of our best campaign ever.

For context: industry average email open rate is 21%. Ours was 3.7x that. Industry average click rate is 2.6%. Ours was 4.2x that.

This wasn't a fluke. We ran it twice:
- First test (14,059 recipients): 77.5% open, 10.5% CTR
- Full send (78,958 recipients): 78.8% open, 11.0% CTR

The numbers actually got *better* at scale.

People desperately want to know who's looking at their profile. Not "might be interested" — desperately. Nearly 4 out of 5 people opened the email. More than 1 in 10 clicked through.

This is the proof of concept. This is the foundation of everything that follows.

**CLIFFHANGER:**

"But a notification without a next step is a dead end. You see who viewed you... then what? Unless..."

---

### Chapter 5: "The Loop"

**HOOK:**

Profile Views alone is a feature. Profile Views + Chat is a platform.

Here's the loop:

1. You get a notification: "Someone viewed your profile."
2. You open the app. You see who.
3. You view their profile. You see their credits. You realize they worked on something you respect.
4. You send them a message: "Hey, I saw you worked on [Album]. I'm working on something similar — would love to pick your brain."
5. They respond. Now you're in a conversation.
6. They check your profile to learn more about you. That generates a view notification for you.
7. The loop runs itself.

Notification → Curiosity → Profile Visit → Message → Response → Profile Visit → Notification.

Every step feeds the next. Every interaction creates more data, more views, more notifications, more reasons to come back.

This is LinkedIn's playbook — but applied to the only industry where your professional identity is built on verifiable, permanent, credited work. Not job titles. Not self-reported skills. Real credits on real music.

On LinkedIn, you message someone because of their job title. On Muso, you message someone because they played bass on the record that changed your life. That's 10x more targeted. 10x more personal. 10x more valuable.

Now multiply that by 500,000 verified music professionals.

Producers finding engineers. Labels finding talent. Sync supervisors finding artists. Session musicians finding gigs. Managers finding collaborators.

All happening organically, driven by curiosity and verified credibility.

**CLIFFHANGER:**

"Now multiply that by 500,000 music professionals. And ask yourself: what would advertisers pay to be inside that room?"

---

### Chapter 6: "The Real Play"

**HOOK:**

Muso Ads.

The only advertising platform on earth where brands can target verified music professionals by:
- Role (producer, engineer, songwriter, artist, manager, label exec)
- Credits (worked on Grammy-nominated records, top 100 Billboard, indie releases)
- Genre (hip-hop producers, classical session players, electronic artists)
- Career stage (emerging, mid-career, established, legendary)
- Geography (LA, London, Nashville, Berlin, Lagos)

No other platform can do this. Not Meta. Not Google. Not Spotify. Not LinkedIn.

Meta knows what you "like." LinkedIn knows your job title. Spotify knows what you listen to.

Muso knows what you actually made. Verified. Permanent. Uncheatable.

A guitar company can target every guitarist who's been credited on a record in the last 2 years. A plugin maker can target every mix engineer with 50+ credits. A music school can target emerging artists under 25. A distribution company can target independent artists with growing streaming numbers.

The targeting is surgical because the data is real.

But here's the catch — and this is where we need to be brutally honest:

Right now, only 7,217 unique people see our ads in a given week. We pitch "reach 500K professionals" but the delivery rate is 1.4%.

The ads product is real. The targeting is unmatched. The data is verified.

But the room needs to be full.

**CLIFFHANGER:**

"It only works if the room is full. Here's the 90-day plan to fill it..."

---

### Chapter 7: "The Sprint"

**HOOK:**

3 phases. 90 days. One goal: turn Muso from a database into a daily-use platform with enough genuine attention to make ads a real revenue line.

**Month 1 — Ship the Hook:**
- Profile Views: LinkedIn-style "who viewed your profile" with email + push notifications. Lite users see that people viewed them but can't see who (blurred behind Pro paywall). Daily engagement trigger + freemium conversion funnel in one feature.
- Chat: Direct messaging between music professionals. The action that turns a view into a connection.
- Onboarding Fix: Mandatory profile completion (name, role, genre, photo). Because Profile Views + Chat with blank profiles is a ghost town.
- The foundation is already in progress: ADR-029 approved, implementation started, design research complete.

**Month 2 — Flood the Gates:**
- Paid acquisition: Meta ads with new positioning — "The professional network for music. See who's watching your career."
- Influencer seeding: 30 custom plaques to high-profile professionals already on the platform. Get them posting.
- Viral video: 3 concepts designed to showcase the new Muso, not the old database.
- Email blast: Full 367K Klaviyo list activation. If we hit even half our test CTR, that's 29,000 people flooding back to the platform in one day.

**Month 3 — Sell the Attention:**
- With 2 months of real engagement data, we go to advertisers with honest, verifiable metrics: actual DAU, actual session time, actual ad impressions per user.
- Updated B2B pitch: move from "500K profiles" to "X daily active professionals spending Y minutes per session."
- Case studies from existing ad partners (MWTM: $6,127.80/mo contract. SSL. Casio.).
- Run the outreach engine on the full prospect pipeline with the updated pitch.

**The targets:**
- DAU: 13K quiet-day → 25K+ (Month 1) → 50K+ (Month 2) → 75K+ (Month 3)
- MAU: 70K → 120K → 150-200K
- Weekly ad impressions: 34K → 75K+
- MRR: $192K → $210K+ (from Profile Views paywall conversions alone)
- New B2B ad deals: 3-5 closed in Month 3

**The budget:** $52K minimum, $75K recommended, $107K aggressive — mostly paid acquisition. Everything else is already being built.

**The honest risks:** Timeline is aggressive. Chat could flop without onboarding. Paid CPA might be too high for our niche. But the Profile View email test — 79% open rate, 11% click rate, 6.8x better than anything else we've ever sent — says the underlying demand is there. People want this. We just need to build it and put it in front of them.

**END:**

"This isn't a product update. This isn't a feature launch. This is Muso becoming what it was always supposed to be.

Not a database. Not a reference tool.

The professional network for everyone who makes music.

The room where the industry connects, discovers, and does business.

And the only place on earth where brands can reach them — verified, engaged, and paying attention."

---

*Document generated April 16, 2026. Data pulled live from Amplitude, ChartMogul, Klaviyo, and AMP daily reports. All numbers are as of query time — verify against dashboards before presenting.*
