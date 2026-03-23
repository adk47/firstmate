# User Request Handling Workflow

Source: KT 2026-01-20 (Oleg Mamchich)

## ClickUp Task Management

User requests flow through ClickUp's "user requests" list:

| Status | Meaning |
|--------|---------|
| **To-do** | Actionable, ready to process |
| **Waiting** | Blocked, needs engineering fix or external resolution |
| **Impossible** | Cannot be resolved (Spotify issues, etc.) |
| **Resolved** | Successfully completed |

### Required Fields

Operations must always include:
- **Profile ID** (from Muso URL)
- **User Email**

### Task Assignment

- Tasks default to Keplo team
- Assign to self when working
- Move back to creator (e.g., Kevin) when resolved or blocked

## Common Request Types

| Request | Resolution |
|---------|------------|
| **Credits not appearing** | Usually Spotify scraping issues; check CloudWatch SLA dashboard |
| **Profile deletion** | See `entity_deletion.md` |
| **Profile merge** | Use Retool merge UI |
| **Missing analytics** | Check if profile has active seat + Spotify issues |

## Service Health Check

Before investigating user issues, check service health:

1. **CloudWatch → "analytics" dashboard** (historical name for capture service)
2. **High priority queue** should reach ~0 by end of day
3. **Normal priority queue** should decrease throughout day
4. If Spotify/TikTok queues not decreasing → scraping issues blocking resolution

### Queue Health Indicators

| State | Interpretation |
|-------|---------------|
| Approaching zero by EOD | Healthy |
| Flat line / increasing | Scraping issues or rate limiting |
| Spiky but trending down | Normal processing with bursts |

## Workflow Example: Credit Not Appearing

1. Copy profile ID from task
2. Check CloudWatch for Spotify queue health
3. If Spotify issues active:
   - Reply to task creator: "Spotify issues, partially resolved, please retry"
   - Set status to "Impossible"
   - Move task back to creator
4. If Spotify healthy:
   - Check profile in Retool
   - Verify credit was actually added
   - Trigger manual sync if needed

---

## Additional Request Types

Source: KT 2026-02-03, 2026-02-04

| Request | Resolution |
|---------|------------|
| **Track deletion** | Use Retool delete button. If stream count is very high, check with Aaron first. |
| **"Non-musical" link incorrectly marked** | Fix in Aurora stats DB: set `is_not_music = false`. Stats update next day. |
| **YouTube streams not refreshing** | Run refresh script (selects tracks not updated in 14 days OR zero streams). API in progress. |
| **Remove incorrect credits** | If credit comes from Spotify, user must fix on Spotify first. Muso mirrors industry data. |
| **Merge tracks into album** | **Decline** — Database changes too complex/hacky. Maintain system integrity. |
| **Label disambiguation** | Temporary: create new profile, move credits. See `industry-data/gotchas.md` for details. |
| **YouTube playlist claiming** | If playlist has multiple tracks all belonging to user, assign the single YouTube link to any one track. |

### "Non-Musical" Link Fix Procedure

When a user reports a link incorrectly marked as "non-music":

1. Verify the content is actual music (check YouTube/platform)
2. The "non-music" flag comes from Ops Hub's "risky analytics links"
3. Access Aurora stats database
4. Set `is_not_music = false` for the link
5. Stats update next day when pipeline runs
6. No easy way to unmark in Retool currently

### Credits From Spotify (Mirror Limitation)

Muso acts as a **mirror** of what exists in the music industry. If incorrect credits come from Spotify:

- Nothing can be done on our side
- User must fix the issue on Spotify directly
- Once fixed on Spotify, Muso will reflect the change

Response template: "Unfortunately, we can't remove these credits because they come from Spotify. You'll need to contact your distributor or Spotify to correct the metadata."

---

Last updated: 2026-02-04 (from KT 2026-02-03, 2026-02-04)
