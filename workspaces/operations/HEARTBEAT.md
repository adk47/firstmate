# HEARTBEAT.md — Operations Agent

⛔ ALL AUTOMATIONS DISABLED — Running on Clio until cutover

## ⚠️ POSTING RULE
All heartbeat output → MAIN CHANNEL (top-level), never in a thread. Use `message(action=send, target=<channel_id>)` with NO `threadId`/`replyTo`.

---

## Daily Claiming Report → #operations (GJAM34DT6)
**Status: DISABLED — awaiting cutover from Clio**

Athena: `public_claiming` JOIN `public_teams`, last 24h. Summary + rejections detail + repeat requesters + missing reasons.

---

## Daily Credit Fraud Scan → #clio_analyst (C0ADREBPNQ2)
**Status: DISABLED — awaiting cutover from Clio**

Approved credit_requests, last 24h, Spotify pop≥50. **MANDATORY: Web-verified, per-person fraud assessment.** Never flag on popularity alone.

**For EVERY person in the scan:**
1. **Web research** — Search AllMusic, Discogs, LinkedIn, professional websites, DuckDuckGo. Check if email domain has a matching professional site. Look for Berklee/SAE/etc education signals in .edu emails.
2. **Cross-reference credits** — Do the claimed roles match their verified career? Is a mastering engineer claiming mastering credits (expected) or claiming songwriter credits (suspicious)?
3. **Assign verdict with reasoning:**
   - ✅ *VERIFIED LEGIT* — Found confirming web presence (studio website, AllMusic/Discogs credits, LinkedIn with career history, .edu email). State what you found.
   - 🔍 *UNVERIFIABLE — LOW CONCERN* — No web presence found, but credit pattern is consistent (single technical role, professional email handle, specialized skill like Immersive Mixing). State why it's low concern.
   - 🔍 *UNVERIFIABLE — NEEDS REVIEW* — No web presence AND one or more risk signals: very high pop (≥90), creative roles (composer/vocalist/producer) on high-pop tracks, many credits in one batch, mononym profile, generic email. State specific risk signals.
   - 🔴 *SUSPICIOUS* — Active red flags: credit pattern doesn't match verifiable identity, web presence contradicts claimed role, bulk self-additions, disposable email domain, or identity mismatch.

**Output format:** Group by verdict (verified first, then unverifiable low/medium, then suspicious). For each person: name, pop score, credit count + roles, email, profile link, and 1-2 sentence reason for the verdict.

**End with:** Summary counts by category. Only flag items that genuinely warrant ops attention.

Updated Mar 13, 2026 — Aaron requested sophistication: web research + per-person reasoning, not blind popularity flags.

---

## Refund Processor Channel Config
**Status: DISABLED — awaiting cutover from Clio**

Refund investigation and processing results posted to appropriate channels. Uses `muso-refund-processor` skill. Stripe writes require Aaron authorization.
