# Caroline Weekly Review: Grading Rubric

Every dimension scores 0–5. P0/P1/P2 severity per finding. P0 in any dimension forces the Slack headline.

## Severity ladder

- **P0**: any `[intercom:tool-leak]` / `[intercom:email-leak]` audit line in window, OR any regression pattern from Dimension B (analytics→email/support loop).
- **P1**: wrong escalation, wrong actionType/tier, missed required `profile_status` call on an analytics/streams conversation, refund 3-gate skipped.
- **P2**: voice blacklist hit ("Great question", em-dash, "investigate", apologies-for-analytics), KB gap cluster, sentiment issue. Tone lint is not P0.

## Dimension A: Voice + leak audit

Mechanical scans first:
- Em-dash count in outbound bodies, cite conversation IDs.
- Phrase blacklist: "Great question", "I understand your frustration", "investigate", "sorry the analytics are delayed", "sorry for the latency".
- Audit-line count from `audit.jsonl`. Any non-zero is the **top-line of the Slack post**.

Score: 5 if zero leaks AND zero blacklist hits; -1 per blacklist hit; floor 0.

## Dimension B: Tool usage + escalation hygiene

**Prereq-gated.** If `preflight.sh` reports `CV_TOOL_CTX_CONVERSATION_ID=unavailable`, skip this dimension and render "skipped: join-key prereq pending".

- For each conversation mentioning "analytics", "streams", "data", "updating": did Caroline call `profile_status` (joined by `conversation_id`)? If not, P1.
- For each `create_ticket` call: correct `actionType` + tier per `workspaces/support/TOOLS.md`?
- For each refund mention: was `refund-retention` 3-gate run first?
- Regression watch (P0 each):
  - `email support@muso\.ai`
  - `(contact|reach out to|email) support`

Score: 5 if all expected `profile_status` calls fired AND no escalation mismatches AND no regression pattern.

## Dimension C: KB gaps / repeated questions

- Cluster by topic (short noun phrase).
- **N = unique `contact_id`** (primary), `customer_email` fallback only when `contact_id` missing.
- For each cluster N≥3: did Caroline answer from `reference/*.md` or improvise/punt? If improvise/punt → KB-gap candidate (P2).
- Output: `{topic, unique_customers, conversation_ids[], target_path, anchor, insertion, response_pattern}`.

Score: 5 if zero gaps; -1 per gap; floor 0.

## Dimension D: Customer sentiment

- Per-conversation: `resolved` | `escalated` | `frustrated` | `ghosted`.
- Explicit-frustration regex: "you're a bot", "are you actually checking", "this is useless", "human please", repeat-question-after-Caroline-reply.
- Top 3 frustration conversations cited (P2 each).

Score: 5 - frustration_count, floor 0.

## "Good catches"

2–3 conversations where Caroline did particularly well. Cite the conversation_id and quote a single line. Subject to final-output redaction.

## Slack output template

The agent assembles, then pipes through `redact-output.sh`:

```
<@U0AL36NADEY> Caroline weekly review (week of <YYYY-MM-DD>)

*Headline:* <P0_count> P0 / <P1_count> P1 / <P2_count> P2
Voice: <0-5> | Tools: <0-5 or "skipped: join-key prereq pending"> | KB: <0-5> | Sentiment: <0-5>
Conversations reviewed: <n>

*Voice + leak audit* (Voice <0-5>)
• Leak audit lines: <n>
• Em-dashes: <n>, blacklist hits: <n>
• <findings>

*Tool usage + escalation hygiene* (Tools <0-5> or skipped)
• Missed profile_status calls: <n>
• Wrong-tier tickets: <n>
• Regression pattern hits: <n>
• <findings>

*KB gaps / repeated questions* (KB <0-5>)
• <topic>: <N> unique contacts, IDs: <…>
• ...

*Customer sentiment* (Sentiment <0-5>)
• <r> resolved / <e> escalated / <f> frustrated / <g> ghosted
• Top frustration: <conv_id>: "<quote>"

*Good catches*
• <conv_id>: "<quote>"
• ...

*Auto-PR:* <link or "none this week, no KB gap met N>=3 unique-contact bar">
```
