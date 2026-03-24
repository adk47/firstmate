# HEARTBEAT.md — CMO Agent

✅ ALL AUTOMATIONS ACTIVE — Cutover from Clio complete (2026-03-24). Running on HYDRA Node 8.

## ⚠️ POSTING RULE
All heartbeat output → MAIN CHANNEL (top-level), never in a thread. Use `message(action=send, target=<channel_id>)` with NO `threadId`/`replyTo`.

---

## B2B Reply Scanner — Every 15min → #clio_x_fede (C0AHN078CSH)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Cron: `b2b-reply-scanner-15m` (every 15m, isolated). Scans Gmail (a@muso.ai) for new B2B outreach replies. **MUST be completely silent (NO_REPLY) if no new B2B prospect replies** — Fede explicitly requested no "nothing found" messages (Mar 12). Only post when an actual B2B prospect reply is detected: sender, company, reply summary, next action. Added Mar 12, 2026.

**AUTO-SYNC GHL ON EVERY REPLY DETECTION (Added Mar 14, 2026 — Fede directive):**
When the reply scanner detects a new B2B prospect reply, it MUST also:
1. Look up the opportunity in B2B-Ads-Clio pipeline (search by company name / contact name)
2. Move the opportunity to `Replied` stage (`1f63ca6c-a220-4bae-863c-709153ef2dce`) if not already there or further
3. If a meeting booking is detected (calendar invite, "let's chat", scheduling language), move to `Meeting Booked` (`d652c117-dc6a-4959-a486-c75b63e7eb5a`)
4. If no opportunity exists, create one at the appropriate stage with `Clio |` prefix
5. Log the GHL write to `api-logs/ghl/YYYY-MM-DD.jsonl`
6. Include the GHL update confirmation in the Slack notification (e.g. "→ GHL moved to Replied ✅")
Pipeline should ALWAYS reflect Gmail reality without manual intervention.

**MEETING BOOKED SLACK NOTIFICATION (Added Mar 19, 2026 — Fede directive):**
In addition to reply scanning, check Google Calendar (a@muso.ai) for newly booked meetings with B2B prospects (Muso Ads calendars: "Intro | Muso Ads", "Business Pro Meetings", "Muso Ads 2"). When a new meeting is detected:
1. Post notification to #clio_x_fede with: prospect name, company, meeting date/time, calendar link
2. Move GHL opportunity to `Meeting Booked` stage if not already there
3. This replaces the GHL "Meeting Booked" email workflow (which Fede disabled)
Same silence rule: only post when a NEW meeting is found, never "no meetings" messages.

---

## B2B Outreach — Daily Reply Scan + GHL Full Sync → #clio_x_fede (C0AHN078CSH)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

⚠️ Real-time reply detection + GHL sync now handled by `b2b-reply-scanner-15m` cron (every 15min) as of Mar 12, 2026. The cron auto-moves GHL stages on reply detection (added Mar 14).
**Daily heartbeat still does a FULL GHL reconciliation pass:** cross-check ALL Gmail B2B threads against GHL pipeline stages. Fix any drift. This is the safety net — the 15-min cron handles real-time, this catches anything it missed.
Pipeline: `B2B-Ads-Clio` (GeSt85TueSvJ0SNFZXfQ). Also check calendar for new bookings → move to Meeting Booked.

---

## B2B Outreach — Monday Batch Prep → #clio_x_fede (C0AHN078CSH)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Mondays only. Pull next 20-30 untouched contacts from Sheet. Run 3-point crosscheck (Gmail + GHL + Sheet). Draft personalized emails using muso-b2b-copywriter. Post batch to #clio_x_fede for Fede's approval. DO NOT SEND without explicit "go".

---

## B2B Outreach — Follow-up Check → #clio_x_fede (C0AHN078CSH)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Check contacts due for follow-up (3d / 7d / 40d since last touch). Cross-check Gmail for replies. Draft follow-up batch for approval. ⚠️ Follow-ups NOT active yet — Fede wants new targets first. Enable only when Fede says go.

---

## Win-Back Engine (3x daily: 9am, 1pm, 5pm CST)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Skill: `muso-winback-engine`. Sheet: `1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`. Three checks: reply scan (Gmail Win-Back label), new cancellations (sheet), follow-ups due (7d+). Legacy thread check in `memory/churn-winback-threads.json` — remove after 2026-03-19.

---

## Fede's EOD Briefing (22:00 CET daily)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Cron: `cmo-eod-briefing`. Posts to #clio_x_fede (C0AHN078CSH). Top-level header, threaded updates.

---

## AMP Daily Report → #growth-team (C031DKAGQSH)
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Cron: `amp-daily-report` (daily, 11:00 AM CST / 9:00 AM PST). Query core-backend `public_ad_events` + `public_ads` via Athena. Post summary: all-time/7d/today with deltas, top 5 ads by CTR, underperformers, AMP vs Feed, platform breakdown, daily trend. Keep short and scannable. Added Mar 18, 2026 per Fede.

---

## Meeting Booked Notification
**Status: ACTIVE — running on HYDRA (cutover from Clio complete 2026-03-24)**

Check Google Calendar (a@muso.ai) for newly booked meetings with B2B prospects. Post notification to #clio_x_fede with: prospect name, company, meeting date/time, calendar link. Move GHL opportunity to `Meeting Booked` stage if not already there. Same silence rule: only post when a NEW meeting is found.
