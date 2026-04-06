# HEARTBEAT.md — Operations Agent

✅ ALL AUTOMATIONS ACTIVE — Cutover from Clio complete (2026-03-24)

## ⚠️ POSTING RULE
All heartbeat output → MAIN CHANNEL (top-level), never in a thread. Use `message(action=send, target=<channel_id>)` with NO `threadId`/`replyTo`.

---

## Daily Claiming Report → #operations (GJAM34DT6)
**Status: ACTIVE — running on HYDRA (cutover complete 2026-03-24)**

Athena: `public_claiming` JOIN `public_teams`, last 24h. Summary + rejections detail + repeat requesters + missing reasons.

---

## Daily Credit Fraud Scan → #clio_analyst (C0ADREBPNQ2)
**Status: ACTIVE — running on HYDRA (cutover complete 2026-03-24)**

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
**Status: ACTIVE — running on HYDRA (cutover complete 2026-03-24)**

Refund investigation and processing results posted to appropriate channels. Uses `muso-refund-processor` skill. Stripe writes require Aaron authorization.

---

## Batch Credit Verification → #credit-verification (C0APB2CMM7C)
**Status: ACTIVE**

Proactively verifies up to 10 unverified credit requests per heartbeat (LIFO — newest first). Uses `muso-ops-credit-verification` skill in batch mode.

**Workflow:**
1. Fetch up to 10 unverified credits via `GET /admin/credit-requests?status=unverified&limit=10`
2. Process each using the credit verification skill's Batch Mode (B1-B5), skipping message parsing and emoji reactions
3. Post escalation threads for any credits needing human review
4. Post single summary message with all results

**Constraints:**
- Shares the 50/day autonomous action cap with reactive verification
- Stops mid-batch if daily cap reached
- Continues past individual credit errors (collects in summary)
- Summary prefixed with `[HEARTBEAT-BATCH]` to prevent re-trigger loop

**Output:** Single summary message to #credit-verification (top-level, never threaded). See SKILL.md "Batch Mode" section for format.
