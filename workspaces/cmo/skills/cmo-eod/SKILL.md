---
name: cmo-eod
description: Daily End-of-Day briefing skill for Federico Cappuccilli (CMO) at Muso.AI. Triggers every day at 10PM CET. Posts a top-level summary message in #clio_x_fede, then threads all updates beneath it. Use this skill whenever generating or formatting a CMO daily briefing, EOD report, or daily standup summary for Fede. Must be readable by non-technical people.
---

# CMO EOD Briefing

## Purpose
Deliver a concise, scannable daily briefing to Fede (CMO) every night at 10PM CET in the Slack channel **#clio_x_fede**.

---

## Delivery Format

### Top-level message (parent post):
```
Global EOD — [Day, DD MMM YYYY]
```

### Thread reply (all updates go here):

Use bullet points. Each bullet = 1-2 lines max. Group by section. Add a Slack or ClickUp link reference where relevant.

---

## Sections to Cover

**Tech**
- What shipped or was deployed today
- Any major code changes or fixes
- Active blockers or dependencies involving other teams

**Fede / Mentions**
- Any thread, task, or message where Fede is tagged or mentioned
- Anything waiting on Fede's input or approval

**Replies to Fede**
- Any reply to a message Fede sent, across all Slack channels
- Include: channel name, who replied, link to thread
- Group multiple replies from the same thread into one bullet

**Channels**
- #social-media: posts published, content decisions, team updates
- #growth-team: campaigns, metrics, experiments, notable discussions
- #sales-alerts: B2B Ads outreach activity (new)
- #win-back-alerts: churn winback activity (new)
- #company-finder: daily company batches (new)

**Marketing Systems**
- Klaviyo: campaigns sent, flow changes, list/segment updates, template edits in last 24h
- GoHighLevel: workflow changes, campaign activity, pipeline updates (when API access available)
- n8n: workflow executions, new/modified workflows (when API access available)
- Only include items that changed — skip if no activity

**Email (@muso.ai)**
- Notable inbound or outbound from any @muso.ai address
- New leads, partner replies, important threads

**Outreach & Pipeline (3 Point Crosscheck, MANDATORY)**
- **Always crosscheck all 3 sources:** Gmail (across all 4 Muso accounts) + GHL (B2B-Ads-Clio pipeline) + Google Sheet (master leads sheet)
- Gmail: emails sent in last 24h, replies received, calendar bookings (scan all 4 accounts)
- GHL: pipeline stage counts, new opportunities, stage movements (use GET /opportunities/search with page=N, location_id=S5w31kRRgsBjjiVATWlP, pipeline_id=GeSt85TueSvJ0SNFZXfQ)
- Sheet: master leads sheet (1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I), new contacts or leads added
- Outreach log sheet (1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0), new rows or updates
- Pipeline summary: prospects queued, emails sent, replies received, meetings booked
- **Never report partial data as complete.** If pagination fails or a source is unreachable, say so.
- Skip section if no activity across all 3 sources

**Winback & Pipeline (separate from outreach)**
- Crosscheck: Gmail `Win-Back` label (all 4 accounts) + GHL Win Back pipeline (location `fmK5Vl9sJv49WTYA0QyP`, pipeline `AZa8jK5S7UyQ0fqfxzyB`) + Sheet `high_value_churn` (1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs)
- Winback sent today, replies, re subscriptions, marked Lost
- Skip section if no activity

**Fede + Clio Initiatives**
- Summarize active projects and threads from #clio_x_fede (C0AHN078CSH) in last 24h
- This gives Aaron visibility into what Fede and Clio are working on
- Include: what was started, what progressed, what's blocked or waiting on someone

**ClickUp**
- New tasks created or assigned
- Status changes (moved to In Progress, Done, Blocked)
- Overdue or flagged items

**Other**
- Any major update that doesn't fit above
- Decisions made, deals progressing, urgent flags

---

## Rules

1. **Plain English.** No jargon. A non-technical person must understand every bullet.
2. **BRUTALLY SHORT.** Each bullet = ONE line. Max 15 words per bullet. If Fede wants more detail, he'll ask. You are NOT writing a report — you're writing a scannable list.
3. **Specific.** Name the person, task, or channel. Don't be vague.
4. **Referenced.** Link to the Slack thread or ClickUp task where possible. **Always use Slack channel references in `<#CHANNEL_ID>` format so they are clickable** (e.g. `<#C0AFADBE5PH>` not `#social-media`).
5. **No filler.** Skip "everything is fine" updates. Only include what's worth knowing.
6. **Omit empty sections.** If nothing happened in a category, leave it out entirely.
7. **HARD LENGTH CAP.** The entire thread reply must be under 40 bullets total. If you hit 40, cut the least important items. Typical good output = 10-20 bullets.
8. **No sub-bullets.** Flat list only. No nested points. No explanations under a bullet.
9. **Date = today's date.** When triggered by cron at 10PM CET, use today's date. When triggered on-demand, use today's date unless the requester specifies a different day. NEVER guess or use a cached date from a prior run.

---

## Example Output

**Parent message:**
```
Global EOD — Wednesday, 11 Mar 2025
```

**Thread reply:**
```
Tech
- Serhii deployed new search filter to staging. Going live tomorrow pending QA. [link]
- Ihor fixed the broken export button on profiles. Merged this afternoon.

Fede / Mentions
- Aaron tagged you in #product re: AMP launch copy - needs review by Friday [link]
- Jan flagged a ClickUp task: "Casio contract - final review" assigned to you [link]

Replies to Fede
- #ads-outreach: IK Multimedia replied to your follow-up email thread [link]
- #general: Rob Mackie replied to your video brief message [link]

Channels
- #social-media: KZ posted the Poo Bear reel. 3.2K views in 4 hours.
- #growth-team: Push notification test results shared by Jan. 61% open rate confirmed.
- #sales-alerts: 12 outreach sent, 2 replies received.

Email
- Inbound from Roland rep re: NAMM follow-up. Replied by Aaron. [thread]
- IK Multimedia opened the proposal email (tracked).

ClickUp
- 3 new tasks added to AMP Launch sprint [link]
- "Casio campaign - creative brief" moved to In Progress by KZ

Other
- Casio contract signed. Aaron confirmed via Slack DM. Launch March 15 confirmed.
```
