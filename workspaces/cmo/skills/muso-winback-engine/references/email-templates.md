# Email Templates — Win-Back & Lite Upgrade

All emails written as Aaron. Short, personal, reference their public profile. No marketing speak.

## Template Selection Logic

Choose based on: campaign type × profile characteristics × cancel reason (if known).

### For Churned Pro Users

**Pick the primary hook based on their strongest profile signal:**
1. High credits (1000+) + songwriter/producer roles → MLC / royalties angle
2. High credits (500+) + engineer/mixer/mastering → catalog analytics angle
3. Used analytics heavily before cancelling → "you were using this" angle
4. Used audits before cancelling → credit accuracy angle
5. Cancel reason = "too_expensive" / "price" → value reframe + coupon lead
6. Cancel reason = "not_using" → feature discovery angle
7. B2B / organization profile → team/roster angle
8. Default → general "your catalog is still here" angle

### For Lite Upgrade Targets

**Pick based on `target_segment` / `value_prop`:**
1. Active High-Pop (events_90d > 100) → "you're already using it, unlock the rest"
2. B2B / Organization → workspace/roster pitch
3. Power Users → analytics + audit deep dive
4. Dormant High-Pop → "your catalog is massive, here's what you're missing"
5. Default → general Pro value prop

---

## Churned Pro Templates

### Template: MLC_ROYALTIES
**For:** Songwriters, producers, artists with 500+ credits
**Subject:** `{first_name} — quick question about your {credits_count} credits`

```html
<p>Hey {first_name},</p>

<p>I was looking at your profile on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> — {credits_count} credits across {roles} is a serious catalog. I'm reaching out because there's a good chance you have unclaimed mechanical royalties sitting at the MLC that you don't know about.</p>

<p>Our audit tool cross-references your catalog against MLC data and flags the gaps. For someone with your credit count, it's almost always worth a look. Pro also gives you real-time streaming analytics on every track you've worked on — Spotify, YouTube, TikTok, all of it.</p>

<p>If you want to come back and check, use the code LITE20A for 20% off — or LITE10 for 10% off monthly if you just want to dip in: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: CATALOG_ANALYTICS
**For:** Engineers, mixers, mastering engineers with large catalogs
**Subject:** `{first_name} — your {credits_count} credits are still on Muso`

```html
<p>Hey {first_name},</p>

<p>I noticed your profile on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> still has {credits_count} credits — that's a real catalog. Just wanted to let you know that with Pro, every one of those tracks gets streaming analytics across Spotify, YouTube, TikTok, Shazam, and more. Not just the big releases — the deep catalog stuff where you might not have visibility.</p>

<p>If you want to take another look, use LITE20A for 20% off annual or LITE10 for 10% off monthly: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: WERE_USING_IT
**For:** Users who were active on analytics/audits before cancelling
**Subject:** `{first_name} — wanted to follow up`

```html
<p>Hey {first_name},</p>

<p>I saw you had a Pro account on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> and wanted to reach out personally. With {credits_count} credits in your catalog, there's a lot of data there — streaming analytics, audit reports for missing credits, and the MLC royalty check that flags unclaimed mechanicals.</p>

<p>We've been adding a lot recently and I think it'd be worth another look. Use LITE20A for 20% off if you want to jump back in: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: PRICE_SENSITIVE
**For:** Users who cancelled citing price
**Subject:** `{first_name} — something for you`

```html
<p>Hey {first_name},</p>

<p>I know you cancelled your Pro account on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> — totally respect that. I wanted to send you a discount code personally: LITE20A gets you 20% off. If you want to try monthly first, LITE10 gives you 10% off that.</p>

<p>With {credits_count} credits in your catalog, the analytics and audit tools are where the real value is — especially the MLC audit that flags unclaimed royalties. Might be worth a quick look.</p>

<p>https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: FEATURE_DISCOVERY
**For:** Users who cancelled saying they weren't using it
**Subject:** `{first_name} — you might have missed this`

```html
<p>Hey {first_name},</p>

<p>I noticed you had a Pro account on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> and cancelled because you weren't getting enough out of it. Totally fair. I wanted to point out a couple things you might not have tried — the MLC audit tool that finds unclaimed mechanical royalties in your catalog, and the Discovery feature where you can track any artist or collaborator's streaming analytics in real-time.</p>

<p>With {credits_count} {roles} credits, there's a lot of data sitting there. If you want another shot, LITE20A gets you 20% off: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: TEAM_ROSTER
**For:** B2B / organization profiles
**Subject:** `{first_name} — question about {profile_name}`

```html
<p>Hi {first_name},</p>

<p>I saw that {profile_name} has {credits_count} credits on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> — that's a significant catalog. I wanted to reach out because our Business plan might make more sense for you than individual Pro. You get roster management for your whole team, each person gets their own free account tied to your workspace, and you get streaming analytics and audit reports across your entire catalog.</p>

<p>The MLC audit in particular has been a big deal for labels and publishers — it flags unclaimed mechanical royalties that most teams don't even know exist.</p>

<p>Would it be worth a quick look? Happy to walk through what the data looks like for {profile_name} specifically.</p>

<p>Aaron</p>
```

### Template: GENERAL_WINBACK
**For:** Default when no strong signal
**Subject:** `{first_name} — your Muso profile`

```html
<p>Hey {first_name},</p>

<p>I was looking at your profile on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> — {credits_count} credits is nothing to ignore. Your catalog is still there, and with Pro you'd get streaming analytics on every track, audit reports that flag missing credits, and the MLC tool that finds unclaimed royalties.</p>

<p>If you want to come back, LITE20A gets you 20% off: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

---

## Lite Upgrade Templates

### Template: ACTIVE_POWER_USER
**For:** Lite users with high engagement (events_90d > 50)
**Subject:** `{first_name} — thought you'd want to see this`

```html
<p>Hey {first_name},</p>

<p>I was looking at your profile on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> and noticed you've got {credits_count} credits — {roles} across a serious catalog. You've been using the platform, so I figured I'd reach out personally.</p>

<p>With Pro, you'd unlock streaming analytics on every track you've worked on (Spotify, YouTube, TikTok, Shazam, all of it), plus the MLC audit tool that flags unclaimed mechanical royalties in your catalog. For someone with your credit count, it's almost always worth running.</p>

<p>Use LITE20A for 20% off annual or LITE10 for 10% off monthly: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: DORMANT_WHALE
**For:** High popularity / high credits but low recent activity
**Subject:** `{first_name} — quick note about your {credits_count} credits`

```html
<p>Hey {first_name},</p>

<p>You probably don't think about this much, but you have {credits_count} credits on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>. That's one of the larger catalogs on the platform.</p>

<p>I'm reaching out because most of that catalog is sitting there without analytics attached. With Pro, you'd get streaming data on every track across all platforms, and the audit tool can flag missing credits and unclaimed MLC royalties. With a catalog your size, the data alone is worth a look.</p>

<p>LITE20A gets you 20% off if you want to check it out: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: LITE_B2B
**For:** Organization/label Lite profiles
**Subject:** `{first_name} — {profile_name} on Muso`

```html
<p>Hi {first_name},</p>

<p>I saw that {profile_name} is on <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a> with {credits_count} credits. I wanted to reach out because our Business plan gives you roster management for your whole team — each person gets their own free Muso account, you get streaming analytics across your entire catalog, and the MLC audit tool flags unclaimed mechanical royalties.</p>

<p>For a catalog with {credits_count} credits, there's almost certainly uncollected revenue sitting at the MLC. Worth a look?</p>

<p>Aaron</p>
```

---

## Follow-Up Templates

### Template: FOLLOWUP_GENTLE
**For:** Day 7 follow-up, no reply to initial
**Subject:** `Re: {original_subject}` (reply to the same thread)

```html
<p>Hey {first_name}, just bumping this in case it got buried. Wanted to make sure you saw the discount code — LITE20A for 20% off.</p>

<p>No pressure either way. Your profile with {credits_count} credits isn't going anywhere.</p>

<p>Aaron</p>
```

---

## Needs Help / Onboarding Rescue Templates (0-credit users)

### Template: NEEDS_HELP_SETUP
**For:** Type 5 — claimed profile but 0 credits, no profile_id linked. Got stuck in onboarding.
**Subject:** `{first_name} — need a hand getting set up on Muso?`

```html
<p>Hey {first_name},</p>

<p>I'm Aaron, the founder of <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>. I noticed you signed up for Pro but it looks like your profile might not be fully connected yet. That happens sometimes — our catalog has millions of credits, but linking yours can take a few steps.</p>

<p>I'd genuinely like to help you get set up. If you tell me your artist/producer name and a couple of tracks you've worked on, I can make sure your credits are properly connected and you can see the full picture — streaming analytics, audit reports, the MLC royalty check, all of it.</p>

<p>And here's a code to come back at 20% off: LITE20A at https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: ROSTER_TRACKER
**For:** Type 2 — 0 credits but actively used Roster to track others
**Subject:** `{first_name} — your Roster on Muso`

```html
<p>Hey {first_name},</p>

<p>I'm Aaron, founder of <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>. I noticed you were using Muso to track artists and collaborators — that's actually one of the most powerful parts of Pro. Real-time streaming analytics on anyone in your Roster, across Spotify, YouTube, TikTok, Shazam, and more.</p>

<p>If you're managing artists, scouting talent, or just keeping tabs on your network, Pro gives you a dashboard nobody else has — verified credits and real performance data, not inflated social numbers.</p>

<p>Here's 20% off if you want to pick it back up: LITE20A at https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: CREDIT_BUILDER
**For:** Type 3 — 0 credits but was submitting credit corrections. Building their catalog.
**Subject:** `{first_name} — let's get your credits sorted`

```html
<p>Hey {first_name},</p>

<p>I'm Aaron, founder of <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>. I saw you were adding credits to your profile — that's exactly what the platform is for. Building a verified credit history is one of the most valuable things you can do for your career, and it sounds like you were in the middle of it.</p>

<p>If you hit any snags getting your credits connected, I'm happy to help personally. Just reply with your artist name and a few tracks and I'll make sure everything's linked up properly. Pro also gives you the audit tools to find credits you might be missing, plus the MLC check for unclaimed royalties.</p>

<p>Here's 20% off to come back: LITE20A at https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: POWER_BROWSER
**For:** Type 4 — 0 credits, no roster/submissions, but heavy browsing/analytics/audit usage
**Subject:** `{first_name} — wanted to reach out`

```html
<p>Hey {first_name},</p>

<p>I'm Aaron, founder of <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>. I saw you had a Pro account and wanted to check in — it looked like you were exploring the platform but your profile might not have been fully set up. That's on us, and I'd like to help.</p>

<p>If you're a musician, producer, engineer, or songwriter, I can personally make sure your credits are properly connected so you can see the full analytics, run audit reports, and check for unclaimed MLC royalties. Just reply with your name and a couple of tracks.</p>

<p>Here's 20% off if you want to give it another go: LITE20A at https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

### Template: TIRE_KICKER
**For:** Type 6 — minimal engagement, generic short pitch
**Subject:** `{first_name} — your Muso account`

```html
<p>Hey {first_name},</p>

<p>I'm Aaron from <a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>. I noticed you tried Pro and wanted to reach out personally — if you didn't get a chance to explore everything, the analytics and audit tools are where the real value is. The MLC royalty check alone has helped a lot of people find money they didn't know existed.</p>

<p>LITE20A gets you 20% off if you want another look: https://app.muso.ai/pricing?plan=pro</p>

<p>Aaron</p>
```

---

## Template Selection Quick Reference

| User Type | Signal | Template |
|-----------|--------|----------|
| Type 1 | Has credits + songwriter/producer | MLC_ROYALTIES |
| Type 1 | Has credits + engineer/mixer | CATALOG_ANALYTICS |
| Type 1 | Has credits + was active on features | WERE_USING_IT |
| Type 1 | Has credits + cancelled for price | PRICE_SENSITIVE |
| Type 1 | Has credits + cancelled "not using" | FEATURE_DISCOVERY |
| Type 1 | Has credits + org/label profile | TEAM_ROSTER |
| Type 1 | Has credits + no strong signal | GENERAL_WINBACK |
| Type 2 | 0 credits + used roster | ROSTER_TRACKER |
| Type 3 | 0 credits + submitted credits | CREDIT_BUILDER |
| Type 4 | 0 credits + heavy browsing | POWER_BROWSER |
| Type 5 | 0 credits + claimed but not linked | NEEDS_HELP_SETUP |
| Type 6 | 0 credits + minimal engagement | TIRE_KICKER |
| Any | Active Lite user (50+ events) | ACTIVE_POWER_USER |
| Any | High pop Lite, low activity | DORMANT_WHALE |
| Any | Lite org/label | LITE_B2B |
| Any | Follow-up (day 7) | FOLLOWUP_GENTLE |
