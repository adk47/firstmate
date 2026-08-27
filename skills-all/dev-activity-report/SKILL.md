---
name: dev-activity-report
description: |
  Generate daily developer activity reports from GitHub commits across Muso-AI org repos.
  Shows big-picture problems solved, individual commits with line counts, and cadence metrics.
  Posts formatted reports to Slack channels.

  Use when: generating dev reports, showing commit activity, reviewing what a developer worked on,
  daily standup summaries, showcasing development velocity, or any "what did X work on" question.

  Triggers: "dev report", "daily report", "commit report", "what did X work on",
  "developer activity", "show commits", "dev activity", "velocity report"
---

# Dev Activity Report

Generate formatted developer activity reports from GitHub commits across all Muso-AI org repos.

## Data Collection

Run the collection script:
```bash
${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/dev-activity-report/scripts/dev-report.sh <github_username> [hours_back]
```

Default: 24 hours. The script scans: core-backend, web-credits, platform-data-processing,
industry-data-processing, analytics-worker, analytics-scheduler, devops, mobile, muso-skills, clio-workspace.

Output format: structured lines (`REPO:`, `COMMIT:sha|adds|dels|message|date`, `SUMMARY`).

## GitHub Username Map

- Aaron Kaufman → `adk47`
- ~~Serhii Ostapchuk → `liflovs`~~ (left the company 2026-08-26 — drop from new reports)
- Add new devs here as needed (check `gh api repos/Muso-AI/<repo>/commits --jq '.[].author.login'`)

## Report Format (Slack mrkdwn)

Structure the report in this order:

1. **Header**: `:rocket: *Daily Dev Report — {Name} (@{username}) — {date}*`

2. **Big Picture: Problems Solved** (`:dart:`)
   - Group related commits into 2-5 themes
   - Explain *what* was accomplished and *why* it matters
   - Use business language, not just commit messages
   - This is the most important section — it tells the story

3. **Commit Stats** (`:bar_chart:`)
   - Per-repo: repo name, commit count, additions/deletions
   - Grand total: total commits, total additions/deletions

4. **Individual Commits** (`:page_facing_up:`)
   - Grouped by repo
   - Format: `• \`sha\` message (+adds/-dels)`
   - Skip version bump commits in the big picture section (still list them here)

5. **Cadence** (`:zap:`)
   - Total commits over time period
   - Average interval between commits (total hours / commit count)

## Slack Formatting Rules

- No markdown tables — use bullet lists
- Use Slack mrkdwn: `*bold*`, `_italic_`, `:emoji:`, `\`code\``
- Keep the report scannable — busy people read this

## Scheduled Usage

For daily automated reports, add a cron entry or HEARTBEAT.md task:
- Default schedule: 2am CST (00:00 PST) daily
- Default channel: #devops_opsworks (C0ACLSLFXAR)
- If zero commits in period, post a short "No commits yesterday" note

## Running for Multiple Devs

The script accepts any GitHub username. To generate reports for the whole team,
run it once per developer. Post each dev's report separately for readability.
