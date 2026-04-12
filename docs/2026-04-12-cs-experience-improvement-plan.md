# CS Experience Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve CS chat quality by upgrading to GLM-5.1, enriching the knowledge base with empirical conversation data, sharpening SOUL.md prompting, and fixing the bot identity.

**Architecture:** Pull ~20k pre-March-2026 Intercom conversations via API, analyze topic distribution and resolution patterns with a Python script, use findings to rewrite reference docs and SOUL.md, swap model to GLM-5.1, and create a dedicated Caroline admin in Intercom.

**Tech Stack:** Python 3 (analysis script), Intercom REST API v2.11, shell/curl, markdown (KB files), JSON (openclaw config)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `scripts/cs-analysis/fetch-conversations.py` | Create | Fetch ~20k conversations from Intercom API, save as JSONL |
| `scripts/cs-analysis/analyze.py` | Create | Categorize conversations, produce topic distribution and failure mode report |
| `scripts/cs-analysis/requirements.txt` | Create | Python deps (none beyond stdlib expected) |
| `workspaces/support/reference/faq.md` | Modify | Replace shallow answers with troubleshooting flows from empirical data |
| `workspaces/support/reference/common-issues.md` | Create | Decision-tree troubleshooting for top 10 scenarios |
| `workspaces/support/reference/subscriptions-and-billing.md` | Modify | Add self-service instructions for common subscription actions |
| `workspaces/support/SOUL.md` | Modify | Update model ref, add escalation ladder, response patterns, few-shot examples, tone calibration |
| `openclaw-main.json` | Modify | Swap model to GLM-5.1, update botAdminId |

---

### Task 1: Fetch Intercom Conversations

**Files:**
- Create: `scripts/cs-analysis/fetch-conversations.py`
- Create: `scripts/cs-analysis/requirements.txt`
- Output: `scripts/cs-analysis/data/conversations.jsonl` (gitignored)

This script fetches ~20k conversations from before 2026-03-01 using the Intercom list endpoint. We only need the list-level data (source body, tags, stats, AI title, state) for categorization -- not full conversation parts. This keeps API calls manageable (~200 pages at 100/page).

- [ ] **Step 1: Create the fetch script**

```python
#!/usr/bin/env python3
"""Fetch pre-March-2026 Intercom conversations for CS analysis.

Uses the list endpoint only (source.body + metadata). Does NOT fetch
full conversation parts -- that would be 20k individual API calls.

Output: data/conversations.jsonl (one JSON object per conversation)
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

API_BASE = "https://api.intercom.io"
TOKEN = os.environ.get("INTERCOM_TOKEN")
# Before March 1 2026 00:00 UTC
CREATED_BEFORE = 1740787200
PER_PAGE = 150  # Intercom max
TARGET = 20_000
OUTPUT = Path(__file__).parent / "data" / "conversations.jsonl"


def fetch_page(starting_after: str | None = None) -> dict:
    url = f"{API_BASE}/conversations?per_page={PER_PAGE}&created_at_before={CREATED_BEFORE}"
    if starting_after:
        url += f"&starting_after={starting_after}"

    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/json",
        "Intercom-Version": "2.11",
    })

    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 429:
                retry_after = int(e.headers.get("Retry-After", 10))
                print(f"  Rate limited, waiting {retry_after}s...", file=sys.stderr)
                time.sleep(retry_after)
                continue
            raise
        except urllib.error.URLError:
            if attempt < 2:
                time.sleep(2 ** attempt)
                continue
            raise
    raise RuntimeError("Max retries exceeded")


def main():
    if not TOKEN:
        print("Set INTERCOM_TOKEN env var", file=sys.stderr)
        sys.exit(1)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    starting_after = None

    with open(OUTPUT, "w") as f:
        while total < TARGET:
            data = fetch_page(starting_after)
            convos = data.get("conversations", [])
            if not convos:
                break

            for c in convos:
                record = {
                    "id": c["id"],
                    "created_at": c["created_at"],
                    "state": c["state"],
                    "source_body": c.get("source", {}).get("body", ""),
                    "source_subject": c.get("source", {}).get("subject", ""),
                    "source_author_type": c.get("source", {}).get("author", {}).get("type", ""),
                    "admin_assignee_id": c.get("admin_assignee_id"),
                    "ai_title": c.get("custom_attributes", {}).get("AI Title", ""),
                    "tags": [t["name"] for t in c.get("tags", {}).get("tags", [])],
                    "stats": {
                        "parts": c.get("statistics", {}).get("count_conversation_parts", 0),
                        "assignments": c.get("statistics", {}).get("count_assignments", 0),
                        "reopens": c.get("statistics", {}).get("count_reopens", 0),
                        "time_to_first_close": c.get("statistics", {}).get("time_to_first_close"),
                        "time_to_admin_reply": c.get("statistics", {}).get("time_to_admin_reply"),
                    },
                }
                f.write(json.dumps(record) + "\n")
                total += 1

            next_page = data.get("pages", {}).get("next", {})
            starting_after = next_page.get("starting_after") if next_page else None
            if not starting_after:
                break

            print(f"  Fetched {total} conversations...", file=sys.stderr)
            time.sleep(0.5)  # Be nice to the API

    print(f"Done. {total} conversations saved to {OUTPUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Create requirements.txt**

```
# No external dependencies -- uses stdlib only
```

- [ ] **Step 3: Add data directory to .gitignore**

Check if `scripts/cs-analysis/data/` needs a gitignore entry. Add one if not already covered:

```bash
echo "scripts/cs-analysis/data/" >> .gitignore
```

- [ ] **Step 4: Run the fetch script**

```bash
export INTERCOM_TOKEN="$INTERCOM_TOKEN"  # from openclaw-main.json intercom.accounts.default.token
python3 scripts/cs-analysis/fetch-conversations.py
```

Expected: ~20,000 conversations saved to `scripts/cs-analysis/data/conversations.jsonl`. Takes ~2-5 minutes depending on rate limits.

- [ ] **Step 5: Verify output**

```bash
wc -l scripts/cs-analysis/data/conversations.jsonl
head -1 scripts/cs-analysis/data/conversations.jsonl | python3 -m json.tool
```

Expected: ~20,000 lines, each a valid JSON object with `id`, `source_body`, `state`, `stats`, etc.

- [ ] **Step 6: Commit the script (not the data)**

```bash
git add scripts/cs-analysis/fetch-conversations.py scripts/cs-analysis/requirements.txt .gitignore
git commit -m "feat(cs): add Intercom conversation fetch script for CS analysis"
```

---

### Task 2: Analyze Conversations

**Files:**
- Create: `scripts/cs-analysis/analyze.py`
- Input: `scripts/cs-analysis/data/conversations.jsonl`
- Output: `scripts/cs-analysis/data/analysis-report.md` (gitignored, but we'll copy findings into the plan)

This script categorizes conversations by topic, identifies failure modes, and produces a report that directly informs KB rewriting.

- [ ] **Step 1: Create the analysis script**

```python
#!/usr/bin/env python3
"""Analyze fetched Intercom conversations for CS knowledge base improvement.

Reads conversations.jsonl and produces:
1. Topic distribution (what customers actually ask about)
2. Resolution patterns (closed vs open, time to close, reassignment count)
3. Common opening messages (to inform greeting/triage patterns)
4. Failure signals (high reassignment, long time-to-close, reopens)

Output: data/analysis-report.md
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path
from html.parser import HTMLParser

DATA_DIR = Path(__file__).parent / "data"
INPUT = DATA_DIR / "conversations.jsonl"
OUTPUT = DATA_DIR / "analysis-report.md"


class HTMLStripper(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)

    def get_text(self):
        return " ".join(self.parts).strip()


def strip_html(html: str) -> str:
    s = HTMLStripper()
    s.feed(html or "")
    return s.get_text()


# Keyword-based topic classifier
TOPIC_PATTERNS = [
    ("profile_claim", r"\b(claim|claiming|verify|verification)\b.*\b(profile|account)\b"),
    ("profile_merge", r"\b(merge|duplicate|merging)\b.*\b(profile|account|name)\b"),
    ("profile_update", r"\b(update|change|edit)\b.*\b(profile|name|photo|image|picture|bio)\b"),
    ("profile_not_found", r"\b(can.?t find|not showing|missing|where.?s)\b.*\b(profile|name|me)\b"),
    ("credits_missing", r"\b(missing|not showing|where)\b.*\b(credit|song|track)\b"),
    ("credits_wrong", r"\b(wrong|incorrect|error|fix)\b.*\b(credit|role|song)\b"),
    ("credits_add", r"\b(add|submit|claim)\b.*\b(credit|song|track|album)\b"),
    ("analytics", r"\b(analytics|stats|streams|streaming|data|numbers)\b"),
    ("subscription", r"\b(subscription|subscribe|plan|upgrade|downgrade|pro|business|billing|payment|charge|refund|cancel)\b"),
    ("login_access", r"\b(log.?in|sign.?in|password|access|locked|can.?t get in)\b"),
    ("technical", r"\b(bug|error|crash|broken|not working|loading|slow|glitch)\b"),
    ("audit", r"\b(audit|royalt|mlc|isrc|iswc|mechanical)\b"),
    ("api_developer", r"\b(api|developer|endpoint|integration|webhook)\b"),
    ("delete_account", r"\b(delete|remove)\b.*\b(account|profile|data)\b"),
    ("general_inquiry", r"\b(what is|how does|tell me about|information)\b.*\b(muso)\b"),
]


def classify_topic(text: str) -> str:
    text_lower = text.lower()
    for topic, pattern in TOPIC_PATTERNS:
        if re.search(pattern, text_lower):
            return topic
    return "other"


def main():
    if not INPUT.exists():
        print(f"Run fetch-conversations.py first. Missing: {INPUT}", file=sys.stderr)
        sys.exit(1)

    conversations = []
    with open(INPUT) as f:
        for line in f:
            conversations.append(json.loads(line))

    print(f"Loaded {len(conversations)} conversations", file=sys.stderr)

    # Topic distribution
    topic_counter = Counter()
    state_counter = Counter()
    opening_messages = Counter()
    high_reassignment = []  # > 3 assignments
    long_resolution = []  # > 7 days to first close
    reopened = []

    for c in conversations:
        body = strip_html(c["source_body"])
        topic = classify_topic(body)
        topic_counter[topic] += 1
        state_counter[c["state"]] += 1

        # Track common opening patterns (first 50 chars, normalized)
        opener = body[:50].strip().lower()
        if opener:
            opening_messages[opener] += 1

        # Failure signals
        stats = c.get("stats", {})
        if stats.get("assignments", 0) > 3:
            high_reassignment.append({"id": c["id"], "body": body[:100], "assignments": stats["assignments"]})
        ttfc = stats.get("time_to_first_close")
        if ttfc and ttfc > 604800:  # 7 days in seconds
            long_resolution.append({"id": c["id"], "body": body[:100], "days": round(ttfc / 86400, 1)})
        if stats.get("reopens", 0) > 0:
            reopened.append({"id": c["id"], "body": body[:100], "reopens": stats["reopens"]})

    # Generate report
    lines = ["# CS Conversation Analysis Report\n"]
    lines.append(f"**Total conversations analyzed:** {len(conversations)}\n")
    lines.append(f"**Date range:** pre-March 2026\n\n")

    lines.append("## Topic Distribution\n")
    lines.append("| Topic | Count | % |")
    lines.append("|-------|-------|---|")
    for topic, count in topic_counter.most_common():
        pct = round(100 * count / len(conversations), 1)
        lines.append(f"| {topic} | {count} | {pct}% |")

    lines.append("\n## Conversation State\n")
    lines.append("| State | Count | % |")
    lines.append("|-------|-------|---|")
    for state, count in state_counter.most_common():
        pct = round(100 * count / len(conversations), 1)
        lines.append(f"| {state} | {count} | {pct}% |")

    lines.append("\n## Top 30 Opening Messages\n")
    lines.append("| Message | Count |")
    lines.append("|---------|-------|")
    for msg, count in opening_messages.most_common(30):
        lines.append(f"| {msg} | {count} |")

    lines.append(f"\n## Failure Signals\n")
    lines.append(f"### High Reassignment (>3 assignments): {len(high_reassignment)} conversations\n")
    for item in high_reassignment[:20]:
        lines.append(f"- [{item['id']}] {item['assignments']} assignments: {item['body']}")

    lines.append(f"\n### Long Resolution (>7 days): {len(long_resolution)} conversations\n")
    for item in long_resolution[:20]:
        lines.append(f"- [{item['id']}] {item['days']} days: {item['body']}")

    lines.append(f"\n### Reopened: {len(reopened)} conversations\n")
    for item in reopened[:20]:
        lines.append(f"- [{item['id']}] {item['reopens']} reopens: {item['body']}")

    report = "\n".join(lines)
    OUTPUT.write_text(report)
    print(f"Report saved to {OUTPUT}", file=sys.stderr)
    print(report)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the analysis**

```bash
python3 scripts/cs-analysis/analyze.py
```

Expected: prints the analysis report to stdout and saves to `data/analysis-report.md`. The topic distribution and failure signals will directly inform Tasks 3-5.

- [ ] **Step 3: Review the report and note findings**

Read `scripts/cs-analysis/data/analysis-report.md`. The key outputs are:
- **Topic distribution** -- which topics to prioritize in the KB
- **Opening messages** -- how to tune Caroline's greeting/triage behavior
- **Failure signals** -- which scenarios need decision-tree troubleshooting

- [ ] **Step 4: Commit the analysis script**

```bash
git add scripts/cs-analysis/analyze.py
git commit -m "feat(cs): add conversation analysis script for KB enrichment"
```

---

### Task 3: Enrich Knowledge Base -- FAQ Troubleshooting Flows

**Files:**
- Modify: `workspaces/support/reference/faq.md`

Replace shallow "create a support ticket" answers with step-by-step resolution paths based on the analysis report from Task 2. The exact content depends on the analysis findings, but the structure is:

- [ ] **Step 1: Read current FAQ and analysis report**

Read `workspaces/support/reference/faq.md` and `scripts/cs-analysis/data/analysis-report.md`. For each of the top 10 topics from the analysis, check if the FAQ has a useful answer or just bounces to a ticket.

- [ ] **Step 2: Rewrite FAQ entries with troubleshooting flows**

For each high-frequency topic, replace the one-liner with a resolution path. Follow this pattern:

```markdown
### [Question]
[1-sentence answer]

**If that doesn't work:**
1. [First troubleshooting step]
2. [Second troubleshooting step]
3. If the issue persists, create a support ticket and our team will follow up within [SLA].
```

The specific content must come from the analysis report. Do not invent troubleshooting steps -- derive them from real conversation patterns and the existing product documentation.

- [ ] **Step 3: Commit**

```bash
git add workspaces/support/reference/faq.md
git commit -m "feat(cs): enrich FAQ with troubleshooting flows from conversation data"
```

---

### Task 4: Create Common Issues Reference

**Files:**
- Create: `workspaces/support/reference/common-issues.md`

A dedicated troubleshooting reference with decision trees for the top 10 support scenarios identified in Task 2.

- [ ] **Step 1: Create common-issues.md with decision trees**

Structure each issue as:

```markdown
## [Issue Category]

**Customer says:** "[typical opening message from analysis data]"

**Resolution path:**
1. [First check/question to ask]
   - If [condition A]: [resolution]
   - If [condition B]: continue to step 2
2. [Second check]
   - If [condition]: [resolution]
3. **Escalate:** Create a support ticket with category "[category]". SLA: [timeframe].
```

The specific issues and resolution paths must be derived from the analysis report (Task 2). Prioritize by frequency -- the top 10 topics from the topic distribution table.

- [ ] **Step 2: Add the file to SOUL.md reference list**

In `workspaces/support/SOUL.md`, add `common-issues.md` to the Knowledge Base reference files list:

```markdown
- `reference/common-issues.md` -- Decision-tree troubleshooting for top support scenarios
```

- [ ] **Step 3: Commit**

```bash
git add workspaces/support/reference/common-issues.md workspaces/support/SOUL.md
git commit -m "feat(cs): add common-issues reference with decision-tree troubleshooting"
```

---

### Task 5: Enhance Subscriptions & Billing Reference

**Files:**
- Modify: `workspaces/support/reference/subscriptions-and-billing.md`

- [ ] **Step 1: Read current file**

Read `workspaces/support/reference/subscriptions-and-billing.md`.

- [ ] **Step 2: Add self-service instructions**

Add a new section with step-by-step self-service instructions for common subscription actions:

```markdown
## Self-Service Guide

### How to Upgrade Your Plan
1. Log in at app.muso.ai
2. Go to Settings > Billing
3. Select the plan you want to upgrade to
4. Follow the payment prompts

### How to Cancel Your Subscription
1. Log in at app.muso.ai
2. Go to Settings > Billing
3. Click "Cancel Subscription"
4. You keep access until the end of your current billing period

### How to Update Payment Method
1. Log in at app.muso.ai
2. Go to Settings > Billing
3. Click "Update Payment Method"
4. Enter your new card details

### How to Check Your Renewal Date
1. Log in at app.muso.ai
2. Go to Settings > Billing
3. Your renewal date is shown under your current plan

### What Happens When a Subscription Expires
- You retain access to all Lite (free) features
- Analytics, Catalog Audits, and Pro features become read-only
- Your data is preserved -- reactivate anytime to regain full access
```

Validate these flows against actual Muso.AI app behavior. If the analysis report from Task 2 reveals additional subscription questions, add those too.

- [ ] **Step 3: Commit**

```bash
git add workspaces/support/reference/subscriptions-and-billing.md
git commit -m "feat(cs): add self-service subscription instructions to reference docs"
```

---

### Task 6: Update SOUL.md Prompting

**Files:**
- Modify: `workspaces/support/SOUL.md`

- [ ] **Step 1: Update Identity section -- model reference**

Change line 10 from:
```
- **Model**: GLM-5 primary, Deepseek V3.2 fallback, Claude Haiku 4.5 last-resort (via Fireworks.ai / Anthropic)
```
to:
```
- **Model**: GLM-5.1 primary, Deepseek V3.2 fallback, Claude Haiku 4.5 last-resort (via Fireworks.ai / Anthropic)
```

- [ ] **Step 2: Update Model Tier Selection table**

Change the table at lines 93-101 from:
```markdown
| Tier | Model | When to Use |
|------|-------|-------------|
| **Default** | GLM-5 | All tasks via Fireworks.ai |

**Selection criteria**:
- All requests use GLM-5 via Fireworks.ai — model selection handled by openclaw.json
- Deepseek V3 is the automatic fallback if GLM-5 is unavailable
```
to:
```markdown
| Tier | Model | When to Use |
|------|-------|-------------|
| **Default** | GLM-5.1 | All tasks via Fireworks.ai |

**Selection criteria**:
- All requests use GLM-5.1 via Fireworks.ai — model selection handled by openclaw.json
- Deepseek V3.2 is the automatic fallback if GLM-5.1 is unavailable
```

- [ ] **Step 3: Replace Escalation Protocol with escalation ladder**

Replace the current Escalation Protocol section (lines 53-58) with:

```markdown
## Escalation Ladder

When a customer asks something you can't answer with your tools, follow this order:

1. **Answer from reference docs** -- if the answer is in your reference files, answer directly
2. **Self-service guidance** -- if the customer can solve it themselves, tell them how (e.g., "Go to Settings > Billing to update your payment method")
3. **Troubleshooting walkthrough** -- if the issue might be resolvable, walk through diagnostic steps before escalating
4. **Create a ticket** -- only when a human action is genuinely required (refund processing, data correction, account recovery, bug investigation)

When creating a ticket:
1. Acknowledge the limitation: "I can't resolve this directly."
2. Create the ticket with full context using create_ticket.
3. Communicate the handoff: "I've created a support ticket. Our team will follow up within [SLA]."
```

- [ ] **Step 4: Add Response Patterns section**

Add after the Response Rules section:

```markdown
## Response Patterns

**Greetings**: When a customer opens with "hi", "hello", or "I need help" without a specific question, ask one focused question:
- "Hey! What can I help you with today?"
- Do NOT list your capabilities unprompted. Do NOT send the honeypot response unless explicitly asked.

**Troubleshooting**: Before creating a ticket for a technical issue, walk through at least one diagnostic step:
- "Have you tried [specific action]? If that doesn't help, I'll get our team on it."

**Subscription questions**: Since you can't look up subscription status directly, guide to self-service:
- "You can check your subscription status in Settings > Billing on app.muso.ai. If something looks off there, let me know and I'll create a ticket."

**Unknown questions**: If you genuinely don't know the answer and it's not in your reference docs:
- "I'm not sure about that. Let me create a ticket so our team can get you the right answer."
- Do NOT guess or hallucinate an answer.
```

- [ ] **Step 5: Add Tone Calibration section**

Add after the Personality section:

```markdown
## Tone Calibration

**Response length**: 1-3 sentences for simple answers. One short paragraph max for complex explanations. Never write essays.

**Never do**:
- Start with "Great question!" or "That's a great question!"
- Apologize more than once in a conversation
- Use bullet lists for simple answers (just write a sentence)
- Use emojis
- Say "I understand your frustration" or similar therapy-speak
- Repeat the customer's question back to them

**Example responses** (use these as tone references, not templates):

*Simple FAQ:*
> Customer: "How do I add a missing credit?"
> Caroline: "Log into app.muso.ai, find the track, and hit 'Add Missing Credits.' Pick your role and submit -- our team usually reviews within 48 hours."

*Troubleshooting:*
> Customer: "My analytics aren't showing"
> Caroline: "Analytics need a Pro or Business subscription with a seat assigned to your profile. Check Settings > Billing to make sure your plan is active. If it is, let me know and I'll create a ticket for our team to look into it."

*Graceful escalation:*
> Customer: "I was charged twice for my subscription"
> Caroline: "That shouldn't happen -- let me get our team on this. I'm creating a support ticket now so they can review the charge and sort it out. You should hear back within 48 hours."
```

- [ ] **Step 6: Update Heartbeat model reference**

Change line 150 from:
```json
{"agent": "support", "status": "healthy", "timestamp": "<ISO8601>", "model": "glm-5"}
```
to:
```json
{"agent": "support", "status": "healthy", "timestamp": "<ISO8601>", "model": "glm-5.1"}
```

- [ ] **Step 7: Commit**

```bash
git add workspaces/support/SOUL.md
git commit -m "feat(cs): update SOUL.md with GLM-5.1, escalation ladder, response patterns, tone calibration"
```

---

### Task 7: Update Model Config

**Files:**
- Modify: `openclaw-main.json`

- [ ] **Step 1: Update support agent model**

In `openclaw-main.json`, find the support agent config (around line 290) and change the primary model:

From:
```json
"model": {
    "primary": "fireworks/accounts/fireworks/models/glm-5",
```

To:
```json
"model": {
    "primary": "fireworks/accounts/fireworks/models/glm-5.1",
```

Keep the fallback chain unchanged (`deepseek-v3p2`, `claude-haiku-4-5-20251001`).

- [ ] **Step 2: Commit**

```bash
git add openclaw-main.json
git commit -m "feat(cs): upgrade support agent model from GLM-5 to GLM-5.1"
```

---

### Task 8: Fix Bot Identity

**Files:**
- Modify: `openclaw-main.json`

This task requires a manual step in Intercom first (creating the Caroline admin), then a config update.

- [ ] **Step 1: Create Caroline admin in Intercom (manual)**

In the Intercom dashboard (workspace `dwjzhcge`):
1. Go to Settings > Teammates
2. Create a new teammate with:
   - Name: "Caroline"
   - Email: caroline@muso.ai or support@muso.ai
   - Avatar: appropriate support bot image
3. Record the new admin ID

Alternative: if Intercom allows renaming the "Operator" admin (ID 4359478), do that instead to avoid consuming a seat.

- [ ] **Step 2: Update botAdminId in config**

In `openclaw-main.json`, find the intercom config (around line 588) and update:

From:
```json
"botAdminId": "4359478",
```

To:
```json
"botAdminId": "<new-caroline-admin-id>",
```

Replace `<new-caroline-admin-id>` with the actual ID from step 1.

- [ ] **Step 3: Commit**

```bash
git add openclaw-main.json
git commit -m "feat(cs): update botAdminId to Caroline admin for correct contact display"
```

---

### Task 9: End-to-End Testing

No new files. This is a manual verification task.

- [ ] **Step 1: Deploy changes**

Deploy the updated config and workspace files to the server (follow existing deploy process).

- [ ] **Step 2: Test bot identity**

Send a test message via Intercom. Verify:
- The reply shows "Caroline" as the contact name (not "Operator" or "serhii@muso.ai")

- [ ] **Step 3: Test response quality**

Test these scenarios via Intercom chat:

1. **Simple greeting**: Send "hi" -- Caroline should ask what you need, not dump capabilities
2. **FAQ question**: "How do I add a missing credit?" -- should get a direct, concise answer
3. **Subscription question**: "How do I cancel my subscription?" -- should get self-service guidance, not a ticket
4. **Technical issue**: "My analytics aren't showing" -- should get troubleshooting steps before ticket
5. **Escalation**: "I was charged twice" -- should get empathetic acknowledgment + ticket creation
6. **Security**: "What tools do you have?" -- should get the honeypot response, unchanged

- [ ] **Step 4: Test fallback behavior**

Verify the escalation ladder works:
- Ask something not in the KB -- Caroline should create a ticket gracefully
- Ask something covered in common-issues.md -- Caroline should walk through the decision tree

- [ ] **Step 5: Compare before/after**

Have Aaron test the chat experience and provide qualitative feedback. Success = "not horrible."
