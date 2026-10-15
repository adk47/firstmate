---
name: cmo-eod
description: Daily End-of-Day briefing skill for Nick (CMO) at Muso.AI. Triggers every day at 10PM CET. Posts a top-level summary message to Nick's Slack DM, then threads all updates beneath it. Use this skill whenever generating or formatting a CMO daily briefing, EOD report, or daily standup summary for Nick. Must be readable by non-technical people.
---

# CMO EOD Briefing

## Purpose
Deliver a concise, scannable daily briefing to Nick (CMO) every night at 10PM CET via **Slack DM to Nick**.

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

**Nick / Mentions**
- Any thread, task, or message where Nick is tagged or mentioned
- Anything waiting on Nick's input or approval

**Replies to Nick**
- Any reply to a message Nick sent, across all Slack channels
- Include: channel name, who replied, link to thread
- Group multiple replies from the same thread into one bullet

**Channels**
- #social-media: posts published, content decisions, team updates
- #growth-team: campaigns, metrics, experiments, notable discussions
- #clio_analyst: reports, insights, data requests

**Marketing Systems**
- Email (our stack, `muso-email` skill): last 24h sends / bounces / unsubscribes by stream and template from `messaging.email_events`, plus Listmonk campaigns sent or scheduled. Run `bash /opt/hydra/scripts/muso-stack-read.sh coverage` first; report only streams that are live on our stack.
- Klaviyo (until each stream and marketing move off it, ~28 Oct): campaigns sent, flow changes, list/segment updates, template edits in last 24h. Once a stream is on our stack, report it from there, not from Klaviyo; never count the same send twice.
- GoHighLevel: workflow changes, campaign activity, pipeline updates (when API access available)
- n8n: workflow executions, new/modified workflows (when API access available)
- Only include items that changed — skip if no activity

**Email (@muso.ai)**
- Notable inbound or outbound from any @muso.ai address
- New leads, partner replies, important threads

**Outreach & Pipeline (3-Point Crosscheck — MANDATORY)**
- **Always crosscheck all 3 sources:** Gmail (a@muso.ai) + GHL (B2B-ADS pipeline) + Google Sheet (clay_n8n_clio_b2b_ads)
- Gmail: emails sent in last 24h, replies received, calendar bookings
- GHL: pipeline stage counts, new opportunities, stage movements (use GET /opportunities/search with page=N, location_id=S5w31kRRgsBjjiVATWlP, pipeline_id=GeSt85TueSvJ0SNFZXfQ)
- Sheet: new contacts/leads added (1Jdp-RKL8tdwx6ySk18u1K97TYTqZjvWyanDIxEWYJrQ)
- B2B Outreach Reports sheet (1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0) — new rows or updates
- Pipeline summary: prospects queued, emails sent, replies received, meetings booked
- **Never report partial data as complete.** If pagination fails or a source is unreachable, say so.
- Skip section if no activity across all 3 sources

**Nick + Clio Initiatives**
- Summarize active projects and threads from #clio_x_fede (C0AHN078CSH) in last 24h
- This gives Aaron visibility into what Nick and Clio are working on
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
2. **BRUTALLY SHORT.** Each bullet = ONE line. Max 15 words per bullet. If Nick wants more detail, he'll ask. You are NOT writing a report — you're writing a scannable list.
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

Nick / Mentions
- Aaron tagged you in #product re: AMP launch copy - needs review by Friday [link]
- Jan flagged a ClickUp task: "Casio contract - final review" assigned to you [link]

Replies to Nick
- #ads-outreach: IK Multimedia replied to your follow-up email thread [link]
- #general: Rob Mackie replied to your video brief message [link]

Channels
- #social-media: KZ posted the Poo Bear reel. 3.2K views in 4 hours.
- #growth-team: Push notification test results shared by Jan. 61% open rate confirmed.
- #clio_analyst: No new reports today.

Email
- Inbound from Roland rep re: NAMM follow-up. Replied by Aaron. [thread]
- IK Multimedia opened the proposal email (tracked).

ClickUp
- 3 new tasks added to AMP Launch sprint [link]
- "Casio campaign - creative brief" moved to In Progress by KZ

Other
- Casio contract signed. Aaron confirmed via Slack DM. Launch March 15 confirmed.
```
