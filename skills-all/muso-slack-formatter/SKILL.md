---
name: muso-slack-formatter
description: |
  MANDATORY output filter for ALL Slack responses. Auto-applies to any skill responding in Slack.

  This skill defines hard rules that MUST be followed before sending ANY message to Slack.
  Violations (like markdown tables) render as garbage and frustrate users.

  Triggers: Automatically active when output destination is Slack (channels, DMs, threads).
  Load order: Apply AFTER composing response, BEFORE sending to Slack.
compatibility: |
  Only relevant when the output destination is Slack (mrkdwn).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Slack Output Filter (MANDATORY)

**This skill auto-applies to ALL Slack output. You do not need to invoke it explicitly.**

## HARD RULES (Never Violate)

### Rule 1: NO MARKDOWN TABLES

```
FORBIDDEN (renders as garbage):
| Column1 | Column2 | Column3 |
|---------|---------|---------|
| Value1  | Value2  | Value3  |
```

**Instead, use ONE of these formats:**

**Option A: Bullet list (preferred for most data)**
```
• MWAA (Airflow): $1,484 — 2 envs (prod Large, dev Medium)
• EKS platform-data: $590 — Control plane + nodes
• S3 Data Lake: ~$800 — Subset of $2,039 total
```

**Option B: Code block with aligned columns (for dense data)**
```
Component           Cost        Notes
─────────────────────────────────────────────────
MWAA (Airflow)      $1,484      2 envs (prod Large, dev Medium)
EKS platform-data   $590        Control plane + nodes
S3 Data Lake        ~$800       Subset of $2,039 total
```

**Option C: Key-value pairs**
```
*Component:* MWAA (Airflow)
*Cost:* $1,484
*Notes:* 2 envs (prod Large, dev Medium)
```

### Rule 2: NO MARKDOWN HEADINGS

```
FORBIDDEN:
# Heading 1
## Heading 2
### Heading 3
```

**Instead, use bold text:**
```
*Data Ops Architecture & Costs*

*Components:*
...

*Monthly Costs:*
...
```

### Rule 3: CORRECT BOLD/ITALIC SYNTAX

| Want | Standard Markdown | Slack mrkdwn |
|------|-------------------|--------------|
| Bold | `**text**` | `*text*` |
| Italic | `*text*` | `_text_` |
| Strikethrough | `~~text~~` | `~text~` |

### Rule 4: CORRECT LINK SYNTAX

```
WRONG:  [Click here](https://example.com)
RIGHT:  <https://example.com|Click here>
```

### Rule 5: BULLET MARKERS

```
WRONG:  - Item one
        - Item two

RIGHT:  • Item one
        • Item two
```

## Pre-Send Checklist

Before sending ANY Slack message, verify:

- [ ] No pipe tables (`| ... |`)
- [ ] No markdown headings (`#`, `##`, `###`)
- [ ] Bold uses `*text*` not `**text**`
- [ ] Italic uses `_text_` not `*text*`
- [ ] Links use `<url|text>` not `[text](url)`
- [ ] Lists use `•` not `-`
- [ ] Tables converted to bullets or code blocks

## Quick Reference

### Supported in Slack mrkdwn
- `*bold*`
- `_italic_`
- `~strikethrough~`
- `` `inline code` ``
- ` ```code block``` `
- `> blockquote`
- `• bullet points`
- `1. numbered lists`
- `<url|link text>`
- `<@U12345|user>` mentions
- `<#C12345|channel>` mentions
- `:emoji:` codes

### NOT Supported (will render as literal text)
- `**bold**` (wrong syntax)
- `# headings`
- `| tables |`
- `[links](url)` (wrong syntax)
- `![images](url)`
- HTML tags
- Horizontal rules (`---`)

## Code Block Best Practices

For ASCII diagrams and aligned data, use code blocks:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Source    │────▶│   Queue     │────▶│   Worker    │
└─────────────┘     └─────────────┘     └─────────────┘
```

Keep code blocks:
- Under 60-70 characters wide (avoids wrapping)
- No inline formatting inside (no `*bold*` in code blocks)
- Use box-drawing characters for diagrams: `─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ ▶ ▼`

## Mentions

```
User:      <@U12345678>
Channel:   <#C12345678>
Here:      <!here>
Channel:   <!channel>
Everyone:  <!everyone>
```

## When This Skill Activates

This skill is automatically active when:
- Responding to an @mention in Slack
- Responding to a slash command
- Posting to a Slack channel
- Sending a DM via Slack

No explicit invocation needed. The rules apply to ALL Slack output.
