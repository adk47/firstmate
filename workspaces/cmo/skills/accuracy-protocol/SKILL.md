# Accuracy Protocol — Mandatory Pre-Answer SOP

**Trigger:** ANY question about Muso products, features, pricing, data, or how anything works.

---

## MANDATORY CHECKLIST (run before answering)

### Step 0: Is it a NUMBER about Muso data? (streams, credits, track/credit counts, monthly listeners, rankings)
If yes, do NOT answer from memory, the Help Center, reference docs, or an external tracker — pull it LIVE:
- artist/profile **streams** (incl. "how many streams does X have", "who reached 1B/10B", leaderboards) → run the **`muso-streams-lookup`** skill
- anything else → `muso query` (Trino) or `muso db`
Cite "from Muso's data (cube_analytics_profile_view)…". External trackers (Kworb / Spotify / Chartmetric) are NOT Muso's number — never present them as Muso's. (Steps 1–4 below are for qualitative "how does X work" questions, not figures.)

### Step 1: Check Help Center
- URL: https://help.muso.ai
- Search the relevant collection (Getting Started, Credits, Analytics, Audits, Promotion, etc.)
- If found → verify my answer against it
- If not found → proceed to Step 2

### Step 2: Check Reference Files
- Read `reference/product-naming.md` for product definitions
- Read `reference/data-sources.md` for data provenance
- Read `reference/key-context.md` for operational context
- If found → verify my answer against it
- If not found → proceed to Step 3

### Step 3: Check Past Context
- Search Slack channels I'm in for prior explanations (especially #social-media, #marketing, #clio_x_fede)
- Check my own past messages in channel history
- If found → verify my answer against it
- If not found → proceed to Step 4

### Step 4: STOP AND ASK
If Steps 1-3 did not produce verified information:
- **DO NOT ANSWER**
- **DO NOT GUESS**
- **DO NOT FABRICATE**
- Say: "I'm not sure about this. Let me check with Nick."
- Ping Nick (U0AL36NADEY) with the question

---

## HARD RULES

1. **Never fabricate.** If I don't know, I don't know.
2. **Never guess.** "Probably" = "I don't know."
3. **Never prioritize sounding helpful over being accurate.** A wrong answer is worse than no answer.
4. **Always cite my source.** "According to help.muso.ai..." or "From our conversation on [date]..."
5. **When in doubt, stop.** The checklist exists to prevent the mistake I made with Faith (2026-04-27).
6. **Muso data figures come from Muso's own data tools, never from memory or an external tracker.** A specific-looking number (streams, credits, listeners) I didn't just pull from `muso-streams-lookup` / `muso query` is a fabrication — even if it "sounds right." (2026-06-26: cited Kworb for Drake's streams instead of querying.)

---

## LOGGING

When I answer a product question, note in my response where the info came from:
- "Pulled from help.muso.ai..."
- "From reference/product-naming.md..."
- "From our Slack discussion on [date]..."

This makes my sources visible and auditable.

---

## ORIGIN

Created 2026-04-27 after I fabricated AMP explanation to Faith. Told her AMP = "Ad Measurement Platform" that pushes ads to Spotify/YouTube. Completely made up. AMP = Amplify = personalized career feed inside Muso app. I had written a guide on this 2 days earlier. Misled a newly onboarded team member. Never again.
