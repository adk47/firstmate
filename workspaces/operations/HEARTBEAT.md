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
**Status: ACTIVE — re-enabled on production ops after hardening (PR #94)**

Proactively fetches up to `OPS_BATCH_FETCH_SIZE` unverified credits from the API every 4h (`cron-jobs.json` → `credit-verification-batch-4h`, `0 */4 * * *` UTC) and processes them, posting a summary to `#credit-verification` with a Jan-tagged thread reply. Target throughput: 500 per run × 6 runs/day = up to 3000 credits/day processed. No-reject policy: SUSPICIOUS verdicts move to `user_verification_needed` instead of rejection. Daily autonomous-approval cap: 500/UTC-day — once hit, LEGITIMATE verdicts are logged as `skip_cap` in remaining runs (verification-needed moves and escalations still run).

**Run logs & retention.** Each batch run writes a JSONL log to `OPS_RUNLOG_DIR/YYYY-MM-DD/<run_id>.jsonl` with a `latest.txt` pointer for quick lookup. Every batch also runs `workspaces/operations/skills/muso-ops-credit-verification/scripts/compress-old-logs.sh` which gzips directories older than 30 days. Per `muso-ops-audit` policy, **logs are never deleted** — only compressed. To investigate a past batch: `cat $OPS_RUNLOG_DIR/latest.txt` then inspect the JSONL, or extract an archived day with `tar -xzf $OPS_RUNLOG_DIR/YYYY-MM-DD.tar.gz`.
