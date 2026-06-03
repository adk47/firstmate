# Caroline Weekly Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Drift note (2026-05-26, PR #287 review):** `OPS_CAROLINE_REVIEW_SLACK_CHANNEL` was deleted (channel driven by cron `delivery.to`) and `OPS_CAROLINE_REVIEW_PR_DISABLE` was inverted to opt-in `OPS_CAROLINE_REVIEW_PR_OPEN`. Live SKILL.md is canonical.
>
> **Update (2026-06-01, codex switch):** cron now runs codex `openai/gpt-5.5` (thinking `high`, fallback `claude-4.6-sonnet-20260217`) on `sessionTarget: isolated` (was Opus 4.7 / `main`), matching the operations agent's other codex crons. `cron-jobs.json` is canonical; the `sessionTarget: main` references below (incl. "Tech Stack") are historical.

**Goal:** Add a Monday operations cron that grades the last 7 days of Caroline's Intercom conversations across 4 dimensions, posts a scored review to `#cs_chats` (`C0ANM0PN9L5`), and opens a single weekly PR against `workspaces/support/reference/*.md` when a KB gap repeats across N≥3 unique customers.

**Architecture:** New skill at `workspaces/operations/skills/muso-caroline-weekly-review/` with deterministic bash scripts for preflight, Intercom fetch, audit-log scrape, pre-LLM redaction, clustering, gating, and PR creation. The operations agent reads `SKILL.md`, runs the scripts, grades the redacted data with LLM reasoning, scrubs the final output via `redact-output.sh`, and returns the text as its final assistant message. The cron runner delivers the message to Slack via `announce` mode. The skill never sends to Slack directly. Dimension B (tool-usage grading) is gated by a separate prereq PR that plumbs `conversation_id` into the openclaw tool ctx; if the prereq has not landed, Dimension B is omitted from the review.

**Tech Stack:** bash + jq + curl (Intercom REST 2.11), bats for tests, openclaw cron runner (`agentId: operations`, `sessionTarget: main`, `delivery.mode: announce`), `gh` CLI for PR creation, git via `.githooks/pre-commit` for KB-edit validation.

**Spec:** `docs/superpowers/specs/2026-05-14-caroline-weekly-review-design.md`

---

## File Structure

**New files:**

```
workspaces/operations/skills/muso-caroline-weekly-review/
  SKILL.md
  references/
    grading-rubric.md
    pr-template.md
  scripts/
    preflight.sh
    fetch-conversations.sh
    fetch-audit.sh
    redact.sh
    redact-output.sh
    cluster-questions.sh
    validate-clusters.sh
    open-kb-pr.sh
    tests/
      helpers.bash
      preflight.bats
      fetch-conversations.bats
      redact.bats
      redact-output.bats
      cluster-questions.bats
      validate-clusters.bats
      open-kb-pr.bats
```

**Modified files:**

- `cron-jobs.json` — add one job entry with `enabled: false`.

Each script has one responsibility. Scripts compose via stdin/stdout or via `${WORKDIR}` file conventions; no shared state outside `${WORKDIR}`.

---

### Task 1: Skeleton — SKILL.md + references + helpers.bash

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/SKILL.md`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/references/grading-rubric.md`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/references/pr-template.md`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/helpers.bash`

- [ ] **Step 1: Create the skill directory tree**

```bash
mkdir -p workspaces/operations/skills/muso-caroline-weekly-review/{scripts/tests,references}
```

- [ ] **Step 2: Write `SKILL.md` (workflow contract loaded by the agent at turn time)**

```markdown
# muso-caroline-weekly-review

Weekly review of Caroline's Intercom conversations. Runs every Monday 09:00 Europe/Rome via the operations cron. Returns a scored review as the final assistant message; the cron runner delivers it to `#cs_chats` (`C0ANM0PN9L5`). Optionally opens ONE PR against `workspaces/support/reference/*.md` when a KB gap repeats across ≥3 unique customers.

## When to use

Invoked exclusively by the `caroline-weekly-review` cron entry in `cron-jobs.json`. Do not run interactively without first setting `OPS_CAROLINE_REVIEW_SLACK_CHANNEL` to a shadow channel.

## Hard rules

- **Never post to Slack directly.** Return the review text as the final assistant message. The cron runner delivers it. Double-posting is a regression.
- **Never edit `SOUL.md`, `TOOLS.md`, or `skills/*/SKILL.md`.** Auto-PR is restricted to `workspaces/support/reference/[^/]+\.md$`, enforced mechanically in `validate-clusters.sh`.
- **No em-dashes anywhere.** The repo pre-commit hook blocks them; this skill blocks them earlier in `validate-clusters.sh`.
- **PR requires evidence.** Every cited conversation_id must exist in the fetched data, validated by `validate-clusters.sh`.
- **Dimension B (tool usage) is skipped if `ctx.conversationId` is not plumbed through openclaw tool ctx.** Verified by `scripts/preflight.sh`. Do not fabricate correlation.

## Workflow

### Phase 0 — Preflight

Run `scripts/preflight.sh`. On failure, return a "preflight failed: <reason>" message and stop. Do not attempt grading.

Preflight resolves `botAdminId` from the intercom plugin config and exports `CAROLINE_BOT_ADMIN_ID`, `WORKDIR`, and `FILTER_MODE` (`assignee` or `post-filter`).

### Phase 1 — Fetch (deterministic)

```bash
scripts/fetch-conversations.sh   # writes ${WORKDIR}/conversations.jsonl
scripts/fetch-audit.sh           # writes ${WORKDIR}/audit.jsonl
scripts/redact.sh                # writes ${WORKDIR}/conversations.redacted.jsonl
```

### Phase 2 — Grade (LLM)

Read `references/grading-rubric.md`. Read `${WORKDIR}/conversations.redacted.jsonl` and `${WORKDIR}/audit.jsonl`. Produce structured findings per dimension. Cluster KB-gap candidates by topic via `scripts/cluster-questions.sh`. For clusters with N≥3 unique contacts, draft a proposed insertion into a target `reference/*.md` file.

### Phase 3 — Output

1. Assemble the Slack review text following the template in `references/grading-rubric.md`.
2. If KB-gap clusters with N≥3 evidence exist AND `OPS_CAROLINE_REVIEW_PR_DISABLE` is unset, write the approved cluster set to `${WORKDIR}/approved-clusters.json` and run `scripts/open-kb-pr.sh ${WORKDIR}/approved-clusters.json`. Append the PR URL to the Slack review.
3. Pipe the final Slack review text through `scripts/redact-output.sh` before emitting it as the final assistant message.

## Environment

- `MUSOAI_INTERCOM_TOKEN` — required.
- `OPS_CAROLINE_REVIEW_SLACK_CHANNEL` — defaults to `C0ANM0PN9L5`. Set to a shadow channel during rollout.
- `OPS_CAROLINE_REVIEW_PR_DISABLE` — set to `1` to skip the `gh pr create` step. Skill still returns the review with a "would-have-PRd" section.

## References

- `references/grading-rubric.md` — dimension definitions, scoring, severity, Slack output template.
- `references/pr-template.md` — PR body template.
```

- [ ] **Step 3: Write `references/grading-rubric.md`**

```markdown
# Caroline Weekly Review — Grading Rubric

Every dimension scores 0–5. P0/P1/P2 severity per finding. P0 in any dimension forces the Slack headline.

## Severity ladder

- **P0**: any `[intercom:tool-leak]` / `[intercom:email-leak]` audit line in window, OR any regression pattern from Dimension B (analytics→email/support loop).
- **P1**: wrong escalation, wrong actionType/tier, missed required `profile_status` call on an analytics/streams conversation, refund 3-gate skipped.
- **P2**: voice blacklist hit ("Great question", em-dash, "investigate", apologies-for-analytics), KB gap cluster, sentiment issue. Tone lint is not P0.

## Dimension A — Voice + leak audit

Mechanical scans first:
- Em-dash count in outbound bodies — cite conversation IDs.
- Phrase blacklist: "Great question", "I understand your frustration", "investigate", "sorry the analytics are delayed", "sorry for the latency".
- Audit-line count from `audit.jsonl`. Any non-zero is the **top-line of the Slack post**.

Score: 5 if zero leaks AND zero blacklist hits; -1 per blacklist hit; floor 0.

## Dimension B — Tool usage + escalation hygiene

**Prereq-gated.** If `preflight.sh` reports `CV_TOOL_CTX_CONVERSATION_ID=unavailable`, skip this dimension and render "skipped: join-key prereq pending".

- For each conversation mentioning "analytics", "streams", "data", "updating": did Caroline call `profile_status` (joined by `conversation_id`)? If not, P1.
- For each `create_ticket` call: correct `actionType` + tier per `workspaces/support/TOOLS.md`?
- For each refund mention: was `refund-retention` 3-gate run first?
- Regression watch (P0 each):
  - `email support@muso\.ai`
  - `(contact|reach out to|email) support`

Score: 5 if all expected `profile_status` calls fired AND no escalation mismatches AND no regression pattern.

## Dimension C — KB gaps / repeated questions

- Cluster by topic (short noun phrase).
- **N = unique `contact_id`** (primary), `customer_email` fallback only when `contact_id` missing.
- For each cluster N≥3: did Caroline answer from `reference/*.md` or improvise/punt? If improvise/punt → KB-gap candidate (P2).
- Output: `{topic, unique_customers, conversation_ids[], target_path, anchor, insertion}`.

Score: 5 if zero gaps; -1 per gap; floor 0.

## Dimension D — Customer sentiment

- Per-conversation: `resolved` | `escalated` | `frustrated` | `ghosted`.
- Explicit-frustration regex: "you're a bot", "are you actually checking", "this is useless", "human please", repeat-question-after-Caroline-reply.
- Top 3 frustration conversations cited (P2 each).

Score: 5 - frustration_count, floor 0.

## "Good catches"

2–3 conversations where Caroline did particularly well. Cite the conversation_id and quote a single line. Subject to final-output redaction.

## Slack output template

The agent assembles, then pipes through `redact-output.sh`:

```
<@U0AL36NADEY> — Caroline weekly review, week of <YYYY-MM-DD>

*Headline:* <P0_count> P0 / <P1_count> P1 / <P2_count> P2
Voice: <0-5> | Tools: <0-5 or "skipped: join-key prereq pending"> | KB: <0-5> | Sentiment: <0-5>
Filter mode: <assignee|post-filter> | Conversations reviewed: <n>

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
• <topic>: <N> unique contacts — IDs: <…>
• ...

*Customer sentiment* (Sentiment <0-5>)
• <r> resolved / <e> escalated / <f> frustrated / <g> ghosted
• Top frustration: <conv_id> — "<quote>"

*Good catches*
• <conv_id>: "<quote>"
• ...

*Auto-PR:* <link or "none this week — no KB gap met N>=3 unique-contact bar">
```
```

- [ ] **Step 4: Write `references/pr-template.md`**

```markdown
## Summary

Weekly Caroline review for {{WEEK_OF}} surfaced {{CLUSTER_COUNT}} KB-gap cluster(s) with N>=3 unique-contact evidence. This PR proposes the edits.

## Clusters

{{CLUSTERS_BLOCK}}

## Out of scope for auto-PR

This PR ONLY edits `workspaces/support/reference/*.md`. Findings that would require changes to `SOUL.md`, `TOOLS.md`, or `skills/*/SKILL.md` are listed in the Slack post for human review (`C0ANM0PN9L5`).

## Verification

- [x] pre-commit hooks pass
- [ ] Nick: review for voice + accuracy
- [ ] Nick: confirm conversation IDs back the proposed edits

🤖 Generated by `muso-caroline-weekly-review` skill
```

Per cluster the agent expands `{{CLUSTERS_BLOCK}}` with:

```markdown
### {{topic}}
- Unique contacts: {{unique_customers}}
- Conversation IDs: {{conversation_ids}}
- Caroline's response pattern: {{response_pattern}}
- Target: `{{target_path}}`
- See the diff for the proposed prose.
```

- [ ] **Step 5: Write `scripts/tests/helpers.bash` (stub openclaw, gh, git, curl)**

```bash
#!/usr/bin/env bash
# Shared helpers for muso-caroline-weekly-review bats tests.
# CRITICAL: PATH-stub external tools so tests never touch prod
# (see feedback_bats_must_stub_openclaw.md).

setup_skill_tmp() {
  export TEST_TMPDIR="$(mktemp -d)"
  export WORKDIR="$TEST_TMPDIR/workdir"
  export OPS_CAROLINE_REVIEW_SLACK_CHANNEL="${OPS_CAROLINE_REVIEW_SLACK_CHANNEL:-C_TEST_CHANNEL}"
  mkdir -p "$WORKDIR"

  mkdir -p "$TEST_TMPDIR/bin"

  # openclaw stub — records calls, never delivers
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf 'openclaw %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/openclaw.calls"
exit 0
STUB

  # gh stub — records calls, simulates success
  cat > "$TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/gh.calls"
case "$1" in
  pr)
    [[ "$2" == "create" ]] && echo "https://github.com/Muso-AI/hydra/pull/9999"
    ;;
  auth)
    [[ "$2" == "status" ]] && exit 0
    ;;
esac
exit 0
STUB

  # curl stub — reads $TEST_TMPDIR/curl-fixture.json if present, else 200 empty
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/curl.calls"
if [ -f "$TEST_TMPDIR/curl-fixture.json" ]; then
  cat "$TEST_TMPDIR/curl-fixture.json"
else
  echo '{}'
fi
exit 0
STUB

  # journalctl stub — reads $TEST_TMPDIR/journal-fixture.txt if present
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf 'journalctl %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/journalctl.calls"
if [ -f "$TEST_TMPDIR/journal-fixture.txt" ]; then
  cat "$TEST_TMPDIR/journal-fixture.txt"
fi
exit 0
STUB

  chmod +x "$TEST_TMPDIR/bin/"*
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Common env used by scripts under test
  export MUSOAI_INTERCOM_TOKEN="test-token"
  export CAROLINE_BOT_ADMIN_ID="caroline-admin-123"
}

teardown_skill_tmp() {
  rm -rf "$TEST_TMPDIR"
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

- [ ] **Step 6: Commit skeleton**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/
git commit -m "feat(ops): scaffold muso-caroline-weekly-review skill

SKILL.md workflow contract, references (rubric + PR template), and bats
helpers.bash that PATH-stubs openclaw, gh, curl, journalctl per
feedback_bats_must_stub_openclaw.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: `redact.sh` (pre-LLM input scrubber)

Strips emails and last names from `conversations.jsonl`; preserves first names for tone grading.

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/redact.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/redact.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

@test "redacts customer email from transcript body" {
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"x1","customer_email":"alice@example.com","customer_first_name":"Alice","customer_last_name":"Smith","parts":[{"author":{"type":"user"},"body":"reach me at alice@example.com or alice.smith@gmail.com"}]}
EOF
  run "$SCRIPTS_DIR/redact.sh" "$WORKDIR/conversations.jsonl" "$WORKDIR/conversations.redacted.jsonl"
  [ "$status" -eq 0 ]
  run grep -c "alice@example.com" "$WORKDIR/conversations.redacted.jsonl"
  [ "$output" -eq 0 ]
  run grep -c "<email>" "$WORKDIR/conversations.redacted.jsonl"
  [ "$output" -ge 2 ]
}

@test "redacts last name in body but keeps first name" {
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"x1","customer_email":"a@b.com","customer_first_name":"Alice","customer_last_name":"Smith","parts":[{"author":{"type":"user"},"body":"hi this is Alice Smith"}]}
EOF
  run "$SCRIPTS_DIR/redact.sh" "$WORKDIR/conversations.jsonl" "$WORKDIR/conversations.redacted.jsonl"
  [ "$status" -eq 0 ]
  grep -q "Alice" "$WORKDIR/conversations.redacted.jsonl"
  ! grep -q "Smith" "$WORKDIR/conversations.redacted.jsonl"
  grep -q "Alice S\." "$WORKDIR/conversations.redacted.jsonl"
}

@test "preserves conversation_id and contact_id" {
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"conv-abc-123","contact_id":"contact-xyz-789","customer_email":"a@b.com","customer_first_name":"A","customer_last_name":"B","parts":[]}
EOF
  run "$SCRIPTS_DIR/redact.sh" "$WORKDIR/conversations.jsonl" "$WORKDIR/conversations.redacted.jsonl"
  [ "$status" -eq 0 ]
  grep -q "conv-abc-123" "$WORKDIR/conversations.redacted.jsonl"
  grep -q "contact-xyz-789" "$WORKDIR/conversations.redacted.jsonl"
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd workspaces/operations/skills/muso-caroline-weekly-review
bats scripts/tests/redact.bats
```

Expected: FAIL with "redact.sh: No such file".

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Scrub customer emails and last names from a conversations.jsonl file
# before LLM grading. Preserves customer_first_name for tone context.
#
# Usage: redact.sh <input.jsonl> <output.jsonl>

set -euo pipefail

INPUT="${1:?input.jsonl required}"
OUTPUT="${2:?output.jsonl required}"

EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

while IFS= read -r line; do
  # Use jq to extract last_name + first_name, then build per-line sed
  last_name=$(printf '%s' "$line" | jq -r '.customer_last_name // empty')
  first_name=$(printf '%s' "$line" | jq -r '.customer_first_name // empty')

  redacted="$line"
  # Strip emails everywhere in the line
  redacted=$(printf '%s' "$redacted" | sed -E "s/${EMAIL_RE}/<email>/g")
  # Strip "First Last" → "First L."
  if [ -n "$first_name" ] && [ -n "$last_name" ]; then
    initial="${last_name:0:1}"
    redacted=$(printf '%s' "$redacted" | sed -E "s/${first_name} ${last_name}/${first_name} ${initial}./g")
    # Also strip bare last-name occurrences
    redacted=$(printf '%s' "$redacted" | sed -E "s/\\b${last_name}\\b/${initial}./g")
  fi
  printf '%s\n' "$redacted"
done < "$INPUT" > "$OUTPUT"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/redact.sh
bats scripts/tests/redact.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/redact.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/redact.bats
git commit -m "feat(ops): redact.sh — pre-LLM PII scrub for conversations.jsonl

Strips emails and last-name occurrences from transcript bodies; keeps
first names for tone-grading signal. bats covers email scrub, last-name
to first-initial, conversation_id preservation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: `redact-output.sh` (final-output scrubber)

Mechanical scrub of Slack body and PR body before delivery. Defends against LLM reintroducing PII from summaries.

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/redact-output.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/redact-output.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

@test "scrubs email reintroduced by LLM in summary text" {
  text='Top frustration: conv-123 — "you should email alice@example.com to fix this"'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"alice@example.com"* ]]
  [[ "$result" == *"<email>"* ]]
}

@test "scrubs phone number" {
  text='customer left phone +1 555 123 4567 in message'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"555 123 4567"* ]]
  [[ "$result" == *"<phone>"* ]]
}

@test "scrubs Stripe customer/payment/charge ids" {
  text='cus_ABC123 pi_xyz_789 ch_FOO456'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" != *"cus_ABC123"* ]]
  [[ "$result" != *"pi_xyz_789"* ]]
  [[ "$result" != *"ch_FOO456"* ]]
  [[ "$result" == *"<stripe_id>"* ]]
}

@test "preserves conversation_id and contact_id" {
  text='conv-abc-123 contact-xyz-789'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"conv-abc-123"* ]]
  [[ "$result" == *"contact-xyz-789"* ]]
}

@test "preserves Slack mention syntax" {
  text='<@U0AL36NADEY> — review'
  result=$(printf '%s' "$text" | "$SCRIPTS_DIR/redact-output.sh")
  [[ "$result" == *"<@U0AL36NADEY>"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats scripts/tests/redact-output.bats
```

Expected: FAIL.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Final-output PII scrub. Reads stdin, writes stdout.
# Defends against the LLM reintroducing PII from summaries — bats fixture
# proves this is a real failure mode.

set -euo pipefail

sed -E \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
  -e 's/\+?[0-9]{1,3}[ -]?\(?[0-9]{2,4}\)?[ -]?[0-9]{2,4}[ -]?[0-9]{2,4}([ -]?[0-9]{1,4})?/<phone>/g' \
  -e 's/\b(cus|pi|ch)_[A-Za-z0-9_]+/<stripe_id>/g'
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/redact-output.sh
bats scripts/tests/redact-output.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/redact-output.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/redact-output.bats
git commit -m "feat(ops): redact-output.sh — final-output PII scrub before delivery

Mechanical sed filter for emails, phones, Stripe ids. Runs on the agent's
final Slack/PR text after grading because the LLM can reintroduce PII
in summaries even when input was redacted. Bats fixture proves this.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: `cluster-questions.sh` (KB-gap clusterer with contact_id dedup)

Takes redacted conversations + an LLM-produced cluster proposal, validates clustering by unique `contact_id`, emits the canonical cluster JSON.

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/cluster-questions.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/cluster-questions.bats`

This script's job: given a proposed cluster `{topic, conversation_ids[]}`, return `{topic, unique_customers, conversation_ids[]}` where `unique_customers` is computed from `contact_id` (fallback `customer_email`). The actual topic discovery is done by the LLM agent; this script just enforces the dedup math.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"contact-A","customer_email":"a@x.com"}
{"id":"c2","contact_id":"contact-A","customer_email":"a@x.com"}
{"id":"c3","contact_id":"contact-B","customer_email":"b@x.com"}
{"id":"c4","contact_id":null,"customer_email":"c@x.com"}
{"id":"c5","contact_id":null,"customer_email":"c@x.com"}
{"id":"c6","contact_id":null,"customer_email":null}
EOF
}
teardown() { teardown_skill_tmp; }

@test "dedups 3 conversations from same contact into N=1" {
  echo '{"topic":"FLAC export","conversation_ids":["c1","c2"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "1" ]
}

@test "counts distinct contact_ids" {
  echo '{"topic":"FLAC export","conversation_ids":["c1","c2","c3"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "2" ]
}

@test "falls back to customer_email when contact_id missing" {
  echo '{"topic":"X","conversation_ids":["c4","c5"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "1" ]
}

@test "ignores blank-contact-and-blank-email rows (does not collapse to 1)" {
  echo '{"topic":"X","conversation_ids":["c6","c6"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "0" ]
}

@test "preserves conversation_ids and topic in output" {
  echo '{"topic":"FLAC export","conversation_ids":["c1","c2","c3"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.topic' "$WORKDIR/out.json")" = "FLAC export" ]
  [ "$(jq -r '.conversation_ids | length' "$WORKDIR/out.json")" = "3" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats scripts/tests/cluster-questions.bats
```

Expected: FAIL with "cluster-questions.sh: No such file".

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Compute unique_customers for a proposed cluster.
# Input on stdin: {"topic": "<str>", "conversation_ids": ["<id>", ...]}
# Input arg 1: path to conversations.jsonl with {id, contact_id, customer_email}
# Output on stdout: {"topic", "unique_customers", "conversation_ids"}.
#
# Dedup key: contact_id; fallback to customer_email when contact_id is null/blank.
# Rows where BOTH contact_id and customer_email are null/blank do not count.

set -euo pipefail

CONVERSATIONS="${1:?path to conversations.jsonl required}"
INPUT="$(cat)"

# Read proposed cluster
TOPIC=$(printf '%s' "$INPUT" | jq -r '.topic')
IDS_JSON=$(printf '%s' "$INPUT" | jq -c '.conversation_ids')

# Build a lookup of id -> dedup_key
LOOKUP=$(jq -nc --slurpfile convs <(jq -c '.' "$CONVERSATIONS") '
  reduce $convs[0] as $c ({}; .[$c.id] = (
    if ($c.contact_id // "" | length) > 0 then "cid:" + $c.contact_id
    elif ($c.customer_email // "" | length) > 0 then "email:" + $c.customer_email
    else null
    end
  ))
')

UNIQUE=$(jq -nr --argjson ids "$IDS_JSON" --argjson lookup "$LOOKUP" '
  [$ids[] | $lookup[.] | select(. != null)] | unique | length
')

jq -nc \
  --arg topic "$TOPIC" \
  --argjson ids "$IDS_JSON" \
  --argjson unique "$UNIQUE" \
  '{topic: $topic, unique_customers: $unique, conversation_ids: $ids}'
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/cluster-questions.sh
bats scripts/tests/cluster-questions.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/cluster-questions.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/cluster-questions.bats
git commit -m "feat(ops): cluster-questions.sh — N=unique contact_id dedup

Takes an LLM-proposed cluster, computes unique_customers from contact_id
(primary) with customer_email fallback. Blank-contact-and-blank-email
rows don't count. Bats covers 3-from-1-contact dedup, email fallback,
and zero-count safety.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: `validate-clusters.sh` (mechanical gate before PR)

Enforces source-ID validation, path allowlist (regex + realpath), voice blacklist, unique-count match. The single non-LLM gate between "agent proposed it" and "PR opens it".

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/validate-clusters.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/validate-clusters.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"A","customer_email":"a@x"}
{"id":"c2","contact_id":"B","customer_email":"b@x"}
{"id":"c3","contact_id":"C","customer_email":"c@x"}
EOF
  # Fake repo root with a reference file
  export REPO_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$REPO_ROOT/workspaces/support/reference"
  touch "$REPO_ROOT/workspaces/support/reference/common-issues.md"
}
teardown() { teardown_skill_tmp; }

good_cluster() {
  jq -nc '{
    week_of: "2026-05-12",
    clusters: [{
      topic: "FLAC export",
      unique_customers: 3,
      conversation_ids: ["c1","c2","c3"],
      target_path: "workspaces/support/reference/common-issues.md",
      anchor: "## Audio file export",
      insertion: "If you need FLAC, request it via the audio settings."
    }]
  }'
}

@test "accepts valid cluster" {
  good_cluster > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "rejects hallucinated conversation_id" {
  good_cluster | jq '.clusters[0].conversation_ids = ["c1","c2","HALLUCINATED"]' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HALLUCINATED"* ]]
}

@test "rejects unique-count mismatch" {
  good_cluster | jq '.clusters[0].unique_customers = 99' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unique_customers"* ]]
}

@test "rejects target outside reference/" {
  good_cluster | jq '.clusters[0].target_path = "workspaces/support/SOUL.md"' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"path"* ]]
}

@test "rejects path traversal via ..." {
  good_cluster | jq '.clusters[0].target_path = "workspaces/support/reference/../SOUL.md"' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "rejects symlink escape" {
  ln -s "$REPO_ROOT/workspaces/support/SOUL.md" "$REPO_ROOT/workspaces/support/reference/sneaky.md"
  good_cluster | jq '.clusters[0].target_path = "workspaces/support/reference/sneaky.md"' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "rejects em-dash in insertion" {
  good_cluster | jq '.clusters[0].insertion = "Try FLAC — fast and lossless."' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"em-dash"* ]]
}

@test "rejects voice-blacklist phrase" {
  good_cluster | jq '.clusters[0].insertion = "Great question! Try FLAC."' > "$WORKDIR/clusters.json"
  run "$SCRIPTS_DIR/validate-clusters.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blacklist"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats scripts/tests/validate-clusters.bats
```

Expected: FAIL.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Mechanical gate before PR creation.
# Validates: every conversation_id exists; unique_customers matches; target
# path canonicalizes inside workspaces/support/reference/; insertion has no
# em-dash or voice-blacklist hit.
#
# Usage: validate-clusters.sh <clusters.json> <conversations.jsonl> <repo_root>
# Exit 0 = all clusters valid. Non-zero = at least one rejected; reasons printed to stderr.

set -euo pipefail

CLUSTERS="${1:?clusters.json required}"
CONVERSATIONS="${2:?conversations.jsonl required}"
REPO_ROOT="${3:?repo root required}"

PATH_REGEX='^workspaces/support/reference/[^/]+\.md$'
BLACKLIST=(
  "Great question"
  "I understand your frustration"
  "investigate"
  "sorry the analytics are delayed"
  "sorry for the latency"
)

# Build set of known conversation IDs
KNOWN_IDS=$(jq -r '.id' "$CONVERSATIONS" | sort -u)

errors=0

cluster_count=$(jq '.clusters | length' "$CLUSTERS")
for i in $(seq 0 $((cluster_count - 1))); do
  topic=$(jq -r ".clusters[$i].topic" "$CLUSTERS")

  # 1. Every cited conversation_id exists
  cited=$(jq -r ".clusters[$i].conversation_ids[]" "$CLUSTERS")
  while IFS= read -r cid; do
    if ! grep -qFx "$cid" <<<"$KNOWN_IDS"; then
      echo "ERROR: cluster '$topic': conversation_id '$cid' not in conversations.jsonl (HALLUCINATED?)" >&2
      errors=$((errors + 1))
    fi
  done <<<"$cited"

  # 2. unique_customers matches recomputed value
  claimed=$(jq -r ".clusters[$i].unique_customers" "$CLUSTERS")
  recomputed=$(jq -c ".clusters[$i] | {topic, conversation_ids}" "$CLUSTERS" \
    | "$(dirname "$0")/cluster-questions.sh" "$CONVERSATIONS" \
    | jq -r '.unique_customers')
  if [ "$claimed" != "$recomputed" ]; then
    echo "ERROR: cluster '$topic': unique_customers mismatch (claimed=$claimed, recomputed=$recomputed)" >&2
    errors=$((errors + 1))
  fi

  # 3. Path allowlist (regex)
  target=$(jq -r ".clusters[$i].target_path" "$CLUSTERS")
  if ! [[ "$target" =~ $PATH_REGEX ]]; then
    echo "ERROR: cluster '$topic': target_path '$target' fails regex path allowlist" >&2
    errors=$((errors + 1))
    continue
  fi

  # 4. realpath canonicalization (rejects .. and symlink escape)
  full_target="$REPO_ROOT/$target"
  if [ ! -e "$full_target" ]; then
    echo "ERROR: cluster '$topic': target_path '$target' does not exist under $REPO_ROOT" >&2
    errors=$((errors + 1))
    continue
  fi
  canonical=$(realpath "$full_target")
  expected_prefix=$(realpath "$REPO_ROOT/workspaces/support/reference")
  if [[ "$canonical" != "$expected_prefix"/* ]]; then
    echo "ERROR: cluster '$topic': target_path '$target' canonicalizes outside reference/ ($canonical)" >&2
    errors=$((errors + 1))
    continue
  fi

  # 5. Em-dash in insertion
  insertion=$(jq -r ".clusters[$i].insertion" "$CLUSTERS")
  if [[ "$insertion" == *"—"* ]]; then
    echo "ERROR: cluster '$topic': insertion contains em-dash" >&2
    errors=$((errors + 1))
  fi

  # 6. Voice blacklist
  for phrase in "${BLACKLIST[@]}"; do
    if [[ "$insertion" == *"$phrase"* ]]; then
      echo "ERROR: cluster '$topic': insertion contains blacklist phrase '$phrase'" >&2
      errors=$((errors + 1))
    fi
  done
done

if [ "$errors" -gt 0 ]; then
  echo "validate-clusters: $errors error(s)" >&2
  exit 1
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/validate-clusters.sh
bats scripts/tests/validate-clusters.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/validate-clusters.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/validate-clusters.bats
git commit -m "feat(ops): validate-clusters.sh — mechanical gate before auto-PR

Source-ID validation, unique_customers recompute-and-match, path
allowlist regex + realpath canonicalization (defends against .. and
symlink escape), em-dash + voice-blacklist scan. Bats covers all
rejection paths.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: `preflight.sh`

Validates the runtime before any fetch. Resolves Caroline's `botAdminId` from intercom config. Tests the `admin_assignee_id` search field and selects `FILTER_MODE`. Tests whether `ctx.conversationId` is plumbed into tool ctx (Dimension B prereq).

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/preflight.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/preflight.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  # Fake intercom plugin config with botAdminId
  export INTERCOM_CONFIG_JSON="$WORKDIR/intercom.json"
  cat > "$INTERCOM_CONFIG_JSON" <<EOF
{"accounts":[{"id":"muso","botAdminId":"caroline-admin-123"}]}
EOF
  # Fake support-tools source path (Dimension B prereq probe target)
  export SUPPORT_TOOLS_INDEX="$WORKDIR/support-tools-index.ts"
  echo "export const tool = (ctx) => { return ctx.sessionId; };" > "$SUPPORT_TOOLS_INDEX"
}
teardown() { teardown_skill_tmp; }

@test "fails when MUSOAI_INTERCOM_TOKEN unset" {
  unset MUSOAI_INTERCOM_TOKEN
  run "$SCRIPTS_DIR/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN"* ]]
}

@test "fails when intercom config missing botAdminId" {
  echo '{"accounts":[{"id":"muso"}]}' > "$INTERCOM_CONFIG_JSON"
  run "$SCRIPTS_DIR/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"botAdminId"* ]]
}

@test "exports CAROLINE_BOT_ADMIN_ID and WORKDIR on success" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123","email":"caroline@muso.ai"}]}
EOF
  run bash -c "source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CAROLINE_BOT_ADMIN_ID|\$WORKDIR|\$FILTER_MODE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"caroline-admin-123"* ]]
  [[ "$output" == *"/workdir-"* || "$output" == *"/tmp/"* ]]
}

@test "fails when git worktree dirty" {
  cd "$TEST_TMPDIR"
  git init -q
  echo "x" > untracked.txt
  run "$SCRIPTS_DIR/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"clean"* ]] || [[ "$output" == *"dirty"* ]]
}

@test "detects CV_TOOL_CTX_CONVERSATION_ID unavailable when support-tools doesn't read ctx.conversationId" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CV_TOOL_CTX_CONVERSATION_ID\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable"* ]]
}

@test "detects CV_TOOL_CTX_CONVERSATION_ID available when support-tools reads ctx.conversationId" {
  echo "export const tool = (ctx) => { return ctx.conversationId; };" > "$SUPPORT_TOOLS_INDEX"
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"admin.list","admins":[{"id":"caroline-admin-123"}]}
EOF
  run bash -c "source '$SCRIPTS_DIR/preflight.sh' && echo \"\$CV_TOOL_CTX_CONVERSATION_ID\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"available"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats scripts/tests/preflight.bats
```

Expected: FAIL.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Preflight checks. Sourceable so successful exports are visible to caller.
# Exports on success:
#   CAROLINE_BOT_ADMIN_ID  — Caroline's Intercom admin id
#   WORKDIR                 — mktemp -d with chmod 700, cleanup trap installed
#   FILTER_MODE             — "assignee" if admin_assignee_id is accepted by
#                             Intercom conversations/search, else "post-filter"
#   CV_TOOL_CTX_CONVERSATION_ID — "available" | "unavailable" (Dimension B gate)

set -euo pipefail

fail() { echo "preflight: $*" >&2; return 1; }

# 1. Required env
[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || fail "MUSOAI_INTERCOM_TOKEN must be set"

# 2. Required tools
for tool in jq gh git curl journalctl realpath; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

# 3. gh auth
gh auth status >/dev/null 2>&1 || fail "gh auth status failed"

# 4. Clean worktree (skip if not in a git repo — e.g. unit-test contexts)
if git rev-parse --git-dir >/dev/null 2>&1; then
  git diff --quiet || fail "worktree not clean (unstaged changes)"
  git diff --cached --quiet || fail "worktree not clean (staged changes)"
  if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    fail "worktree not clean (untracked files present)"
  fi
fi

# 5. Slack channel env
export OPS_CAROLINE_REVIEW_SLACK_CHANNEL="${OPS_CAROLINE_REVIEW_SLACK_CHANNEL:-C0ANM0PN9L5}"

# 6. botAdminId from intercom plugin config
INTERCOM_CONFIG_JSON="${INTERCOM_CONFIG_JSON:-/root/.openclaw-edge/plugins/intercom/config.json}"
[ -f "$INTERCOM_CONFIG_JSON" ] || fail "intercom config not found at $INTERCOM_CONFIG_JSON"
BOT_ADMIN_ID=$(jq -r '.accounts[0].botAdminId // empty' "$INTERCOM_CONFIG_JSON")
[ -n "$BOT_ADMIN_ID" ] || fail "intercom config missing botAdminId"
export CAROLINE_BOT_ADMIN_ID="$BOT_ADMIN_ID"

# 7. Confirm admin exists via /admins
ADMINS=$(curl -sS \
  -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Intercom-Version: 2.11" \
  -H "Accept: application/json" \
  "https://api.intercom.io/admins")
echo "$ADMINS" | jq -e ".admins[] | select(.id == \"$BOT_ADMIN_ID\")" >/dev/null \
  || fail "admin $BOT_ADMIN_ID not present in /admins"

# 8. Conversation-search filter test
PROBE=$(curl -sS -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Intercom-Version: 2.11" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "{\"query\":{\"field\":\"admin_assignee_id\",\"operator\":\"=\",\"value\":\"$BOT_ADMIN_ID\"},\"pagination\":{\"per_page\":1}}" \
  "https://api.intercom.io/conversations/search")
HTTP_CODE=$(printf '%s' "$PROBE" | tail -n1)
if [ "$HTTP_CODE" = "200" ]; then
  export FILTER_MODE="assignee"
else
  export FILTER_MODE="post-filter"
fi

# 9. Tool-ctx prereq probe
SUPPORT_TOOLS_INDEX="${SUPPORT_TOOLS_INDEX:-/root/hydra/plugins/support-tools/src/index.ts}"
if [ -f "$SUPPORT_TOOLS_INDEX" ] && grep -q "ctx\.conversationId\|ctx\[.conversationId.\]" "$SUPPORT_TOOLS_INDEX"; then
  export CV_TOOL_CTX_CONVERSATION_ID="available"
else
  export CV_TOOL_CTX_CONVERSATION_ID="unavailable"
fi

# 10. WORKDIR with cleanup trap
umask 077
WORKDIR=$(mktemp -d -t "caroline-review-XXXXXX")
chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT
export WORKDIR

# 11. Branch absent (only relevant when in repo)
if git rev-parse --git-dir >/dev/null 2>&1; then
  TODAY=$(date -u +%Y-%m-%d)
  BRANCH="auto/caroline-kb-review-$TODAY"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    fail "branch $BRANCH already exists; aborting to avoid clobber"
  fi
fi

echo "preflight: ok (filter_mode=$FILTER_MODE, tool_ctx=$CV_TOOL_CTX_CONVERSATION_ID)"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/preflight.sh
bats scripts/tests/preflight.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/preflight.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/preflight.bats
git commit -m "feat(ops): preflight.sh — env + intercom + tool-ctx probes

Resolves botAdminId from intercom plugin config (types.ts:110), confirms
it via /admins, tests admin_assignee_id search field to choose FILTER_MODE,
probes support-tools for ctx.conversationId to gate Dimension B. Exports
WORKDIR with chmod 700 + cleanup trap.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: `fetch-conversations.sh`

Pulls 7 days of Caroline-touched conversations from Intercom with pagination + `Retry-After` handling.

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/fetch-conversations.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/fetch-conversations.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  export FILTER_MODE="assignee"
}
teardown() { teardown_skill_tmp; }

# The curl stub reads from $TEST_TMPDIR/curl-fixture.json. For
# pagination tests we need a sequence of responses; we use a counter
# file the stub can read.

stub_curl_sequence() {
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
COUNTER="$TEST_TMPDIR/curl.counter"
N=$(cat "$COUNTER" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$COUNTER"
cat "$TEST_TMPDIR/curl-fixture-$N.json"
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
}

@test "writes one line per conversation to conversations.jsonl" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"conversation.list","conversations":[
  {"id":"c1","contact_id":"x1","customer":{"email":"a@x"},"conversation_parts":{"conversation_parts":[
    {"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi"}
  ]}}
],"pages":{"next":null}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/conversations.jsonl" ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
}

@test "follows pages.next.starting_after across pages" {
  stub_curl_sequence
  cat > "$TEST_TMPDIR/curl-fixture-1.json" <<EOF
{"type":"conversation.list","conversations":[{"id":"c1","contact_id":"x1","customer":{"email":"a@x"},"conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi"}]}}],"pages":{"next":{"starting_after":"cursor-2"}}}
EOF
  cat > "$TEST_TMPDIR/curl-fixture-2.json" <<EOF
{"type":"conversation.list","conversations":[{"id":"c2","contact_id":"x2","customer":{"email":"b@x"},"conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi"}]}}],"pages":{"next":null}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 2 ]
}

@test "excludes conversations Caroline did not author" {
  cat > "$TEST_TMPDIR/curl-fixture.json" <<EOF
{"type":"conversation.list","conversations":[
  {"id":"c-human","contact_id":"x1","customer":{"email":"a@x"},"conversation_parts":{"conversation_parts":[
    {"author":{"type":"admin","id":"jan-admin-999"},"body":"human reply"}
  ]}}
],"pages":{"next":null}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl" 2>/dev/null || echo 0)" -eq 0 ]
}

@test "honors Retry-After on 429" {
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
COUNTER="$TEST_TMPDIR/curl.counter"
N=$(cat "$COUNTER" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$COUNTER"
if [ "$N" -eq 1 ]; then
  echo "HTTP/1.1 429 Too Many Requests"
  echo "Retry-After: 1"
  echo ""
  echo "rate limit"
  exit 22
fi
cat "$TEST_TMPDIR/curl-fixture-after.json"
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  cat > "$TEST_TMPDIR/curl-fixture-after.json" <<EOF
{"type":"conversation.list","conversations":[{"id":"c1","contact_id":"x1","customer":{"email":"a@x"},"conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi"}]}}],"pages":{"next":null}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats scripts/tests/fetch-conversations.bats
```

Expected: FAIL.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Fetch 7 days of Caroline-touched conversations from Intercom.
# Requires env from preflight.sh: WORKDIR, CAROLINE_BOT_ADMIN_ID, FILTER_MODE.

set -euo pipefail

: "${MUSOAI_INTERCOM_TOKEN:?MUSOAI_INTERCOM_TOKEN required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"
: "${WORKDIR:?WORKDIR required}"
: "${FILTER_MODE:?FILTER_MODE required}"

OUTPUT="$WORKDIR/conversations.jsonl"
: > "$OUTPUT"

NOW=$(date +%s)
SEVEN_DAYS_AGO=$((NOW - 7 * 86400))

intercom_post() {
  local body="$1" attempt=0 max=3
  while [ "$attempt" -lt "$max" ]; do
    local tmp_headers tmp_body
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    set +e
    curl -sS -D "$tmp_headers" -o "$tmp_body" \
      -X POST \
      -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
      -H "Intercom-Version: 2.11" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "$body" \
      "https://api.intercom.io/conversations/search"
    rc=$?
    set -e
    if grep -q "^HTTP/.* 429" "$tmp_headers" 2>/dev/null; then
      local wait
      wait=$(grep -i "^Retry-After:" "$tmp_headers" | awk '{print $2}' | tr -d '\r')
      [ -z "$wait" ] && wait=$((1 << attempt))
      sleep "$wait"
      attempt=$((attempt + 1))
      rm -f "$tmp_headers" "$tmp_body"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$tmp_headers" "$tmp_body"
      attempt=$((attempt + 1))
      sleep $((1 << attempt))
      continue
    fi
    cat "$tmp_body"
    rm -f "$tmp_headers" "$tmp_body"
    return 0
  done
  echo "intercom_post: exhausted retries" >&2
  return 1
}

build_query() {
  local cursor="${1:-}"
  local pagination='{"per_page":150}'
  [ -n "$cursor" ] && pagination="{\"per_page\":150,\"starting_after\":\"$cursor\"}"
  if [ "$FILTER_MODE" = "assignee" ]; then
    jq -nc \
      --argjson since "$SEVEN_DAYS_AGO" \
      --arg admin "$CAROLINE_BOT_ADMIN_ID" \
      --argjson pagination "$pagination" '
      {query: {operator: "AND", value: [
        {field: "updated_at", operator: ">", value: $since},
        {field: "admin_assignee_id", operator: "=", value: $admin}
      ]}, pagination: $pagination}'
  else
    jq -nc --argjson since "$SEVEN_DAYS_AGO" --argjson pagination "$pagination" '
      {query: {field: "updated_at", operator: ">", value: $since}, pagination: $pagination}'
  fi
}

# Pagination loop
cursor=""
while :; do
  resp=$(intercom_post "$(build_query "$cursor")")
  # Filter to Caroline-authored only, normalize fields
  echo "$resp" | jq -c --arg admin "$CAROLINE_BOT_ADMIN_ID" '
    .conversations[] |
    select([.conversation_parts.conversation_parts[]? |
            select(.author.type == "admin" and .author.id == $admin)] | length > 0) |
    {
      id,
      contact_id: (.contact_id // .contacts.contacts[0].id // null),
      customer_email: (.customer.email // .contacts.contacts[0].email // null),
      customer_first_name: (.customer.name // "" | split(" ")[0]),
      customer_last_name: (.customer.name // "" | split(" ") | .[1:] | join(" ")),
      parts: [.conversation_parts.conversation_parts[]? | {author: .author, body: .body}],
      started_at: .created_at,
      closed_at: .updated_at
    }
  ' >> "$OUTPUT"

  cursor=$(echo "$resp" | jq -r '.pages.next.starting_after // empty')
  [ -z "$cursor" ] && break
done

echo "fetch-conversations: wrote $(wc -l < "$OUTPUT") conversations"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/fetch-conversations.sh
bats scripts/tests/fetch-conversations.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/fetch-conversations.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/fetch-conversations.bats
git commit -m "feat(ops): fetch-conversations.sh — 7d Intercom fetch, Caroline-authored

POST conversations/search with Intercom-Version 2.11; pagination via
pages.next.starting_after; honors Retry-After on 429; FILTER_MODE
selects assignee filter vs post-filter; belt-and-braces author.id check
keeps only conversations Caroline actually replied in. Bats covers
pagination, author filter, Retry-After.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: `fetch-audit.sh`

Scrapes 7 days of edge-gateway journal for leak audit lines and (if `CV_TOOL_CTX_CONVERSATION_ID=available`) support-tool calls joined to conversation_id.

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/fetch-audit.sh`

No bats — this is a thin journalctl wrapper. Functional correctness is verified in the manual rollout step.

- [ ] **Step 1: Write the implementation**

```bash
#!/usr/bin/env bash
# Scrape 7 days of edge-gateway journal for sanitizer leak audit lines
# and (when the tool-ctx prereq is landed) support-tool call records.
#
# Output: $WORKDIR/audit.jsonl
# Each line: {"kind": "leak"|"tool_call", ...fields}

set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

OUTPUT="$WORKDIR/audit.jsonl"
: > "$OUTPUT"

# 1. Leak audit lines (always)
journalctl -u openclaw-gateway-edge.service --since "7 days ago" --no-pager \
  | grep -E 'intercom:tool-leak|intercom:email-leak' \
  | while IFS= read -r line; do
      jq -nc --arg raw "$line" '{kind: "leak", raw: $raw}'
    done >> "$OUTPUT" || true

# 2. Support-tool calls (only if prereq landed)
if [ "${CV_TOOL_CTX_CONVERSATION_ID:-unavailable}" = "available" ]; then
  journalctl -u openclaw-gateway-edge.service --since "7 days ago" --no-pager \
    | grep -E 'tool=(profile_status|create_ticket|profile_lookup|credits_search|subscription_status)' \
    | while IFS= read -r line; do
        # Expected log shape (post-prereq):
        #   {"tool":"profile_status","conversation_id":"123","args":{...}}
        if echo "$line" | jq -e '.tool and .conversation_id' >/dev/null 2>&1; then
          echo "$line" | jq -c '{kind: "tool_call", tool, conversation_id, args}'
        fi
      done >> "$OUTPUT" || true
fi

echo "fetch-audit: wrote $(wc -l < "$OUTPUT") audit records"
```

- [ ] **Step 2: Smoke test**

```bash
chmod +x scripts/fetch-audit.sh
WORKDIR=$(mktemp -d) CAROLINE_BOT_ADMIN_ID=dummy CV_TOOL_CTX_CONVERSATION_ID=unavailable \
  scripts/fetch-audit.sh
```

Expected: exits 0, writes `audit.jsonl` (likely empty on dev box).

- [ ] **Step 3: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/fetch-audit.sh
git commit -m "feat(ops): fetch-audit.sh — leak audit + tool-call scrape

journalctl --since '7 days ago' on openclaw-gateway-edge.service. Always
collects intercom:tool-leak / intercom:email-leak lines. Collects
support-tool calls with conversation_id join only when CV_TOOL_CTX_CONVERSATION_ID=available.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 9: `open-kb-pr.sh` (the dangerous one — last and best-tested)

Creates ONE branch, applies edits for ALL approved clusters, runs `.githooks/pre-commit`, opens ONE PR. Safe-restore on any failure.

**Files:**
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/open-kb-pr.sh`
- Create: `workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/open-kb-pr.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  # Build a fake repo
  export REPO_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$REPO_ROOT/workspaces/support/reference" "$REPO_ROOT/.githooks"
  cd "$REPO_ROOT"
  git init -q
  git config user.email "t@t" && git config user.name "t"
  cat > workspaces/support/reference/common-issues.md <<EOF
# Common issues

## Audio file export

Existing prose.
EOF
  # Pass-through pre-commit hook
  cat > .githooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
  chmod +x .githooks/pre-commit
  git add -A && git commit -q -m "init"
  export BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  cat > "$WORKDIR/clusters.json" <<EOF
{
  "week_of": "2026-05-12",
  "clusters": [
    {
      "topic": "FLAC export",
      "unique_customers": 3,
      "conversation_ids": ["c1","c2","c3"],
      "target_path": "workspaces/support/reference/common-issues.md",
      "anchor": "## Audio file export",
      "insertion": "If you need FLAC, request it via the audio settings.",
      "response_pattern": "improvise"
    }
  ]
}
EOF
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"A"}
{"id":"c2","contact_id":"B"}
{"id":"c3","contact_id":"C"}
EOF
}
teardown() { teardown_skill_tmp; }

@test "creates ONE PR for multiple clusters in one branch" {
  jq '.clusters += [{
    "topic": "track delete",
    "unique_customers": 3,
    "conversation_ids": ["c1","c2","c3"],
    "target_path": "workspaces/support/reference/common-issues.md",
    "anchor": "## Audio file export",
    "insertion": "Track deletion is handled in Settings.",
    "response_pattern": "punt"
  }]' "$WORKDIR/clusters.json" > "$WORKDIR/clusters2.json"
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters2.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  grep -c "gh pr create" "$TEST_TMPDIR/gh.calls" >/dev/null
  [ "$(grep -c "gh pr create" "$TEST_TMPDIR/gh.calls")" -eq 1 ]
}

@test "aborts when worktree dirty" {
  cd "$REPO_ROOT"
  echo "dirt" >> workspaces/support/reference/common-issues.md
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dirty"* || "$output" == *"clean"* ]]
}

@test "safe-restore on pre-commit failure" {
  cd "$REPO_ROOT"
  cat > .githooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
  git add .githooks/pre-commit && git commit -q -m "fail hook"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -ne 0 ]
  # Branch should be deleted
  ! git show-ref --verify --quiet "refs/heads/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
  # Should be back on base branch
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BASE_BRANCH" ]
  # No untracked files
  [ -z "$(git ls-files --others --exclude-standard)" ]
}

@test "sets reviewer nicksollazzo on PR" {
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  grep -q "reviewer" "$TEST_TMPDIR/gh.calls"
  grep -q "nicksollazzo" "$TEST_TMPDIR/gh.calls"
}

@test "commit body lists all cluster topics" {
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  run git log -1 --format=%B "auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
  [[ "$output" == *"FLAC export"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats scripts/tests/open-kb-pr.bats
```

Expected: FAIL.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Open ONE PR aggregating ALL approved KB-gap clusters.
# Usage: open-kb-pr.sh <approved-clusters.json> <conversations.jsonl>

set -euo pipefail

CLUSTERS="${1:?clusters.json required}"
CONVERSATIONS="${2:?conversations.jsonl required}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
TODAY=$(date -u +%Y-%m-%d)
AUTO_BRANCH="auto/caroline-kb-review-$TODAY"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

safe_restore() {
  set +e
  git reset --hard >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1
  if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
    git checkout "$BASE_BRANCH" >/dev/null 2>&1
  fi
  git branch -D "$AUTO_BRANCH" >/dev/null 2>&1
  set -e
}

# Worktree must be clean
if ! git diff --quiet || ! git diff --cached --quiet \
     || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "open-kb-pr: worktree not clean — aborting" >&2
  exit 1
fi

# Validate clusters before doing anything destructive
"$SCRIPT_DIR/validate-clusters.sh" "$CLUSTERS" "$CONVERSATIONS" "$REPO_ROOT" >&2 \
  || { echo "open-kb-pr: validate-clusters rejected one or more clusters" >&2; exit 1; }

# Branch
if git show-ref --verify --quiet "refs/heads/$AUTO_BRANCH"; then
  echo "open-kb-pr: branch $AUTO_BRANCH already exists" >&2
  exit 1
fi
git checkout -b "$AUTO_BRANCH" >/dev/null

# Apply each cluster's insertion via python (multi-line safe)
python3 - <<'PY' "$CLUSTERS" "$REPO_ROOT" || { safe_restore; echo "open-kb-pr: apply failed" >&2; exit 1; }
import json, os, re, sys
clusters_path, repo_root = sys.argv[1], sys.argv[2]
data = json.load(open(clusters_path))
for c in data["clusters"]:
    target = os.path.join(repo_root, c["target_path"])
    with open(target) as f:
        content = f.read()
    anchor = c["anchor"]
    insertion = c["insertion"]
    if anchor not in content:
        # No anchor — append under a generated section header
        content = content.rstrip() + f"\n\n{anchor}\n\n{insertion}\n"
    else:
        # Insert immediately after the anchor line + its trailing blank
        pattern = re.escape(anchor) + r"\n+"
        content = re.sub(pattern, lambda m: m.group(0) + insertion + "\n\n", content, count=1)
    with open(target, "w") as f:
        f.write(content)
PY

# Run the repo's pre-commit hook before committing
if [ -x "$REPO_ROOT/.githooks/pre-commit" ]; then
  if ! bash "$REPO_ROOT/.githooks/pre-commit"; then
    safe_restore
    echo "open-kb-pr: pre-commit hook failed — branch restored" >&2
    exit 1
  fi
fi

# Build commit message body listing all cluster topics
COMMIT_BODY=$(jq -r '.clusters | map("- " + .topic + " (N=" + (.unique_customers|tostring) + ", IDs: " + (.conversation_ids | join(", ")) + ")") | join("\n")' "$CLUSTERS")

git add -A
git commit -q -m "chore(support): Caroline KB updates from week of $TODAY

Auto-generated by muso-caroline-weekly-review.

Clusters:
$COMMIT_BODY

Co-Authored-By: Caroline Weekly Review <ops@muso.ai>"

# Build PR body from template
PR_BODY_FILE=$(mktemp)
CLUSTERS_BLOCK=$(jq -r '.clusters | map(
  "### " + .topic + "\n" +
  "- Unique contacts: " + (.unique_customers|tostring) + "\n" +
  "- Conversation IDs: " + (.conversation_ids | join(", ")) + "\n" +
  "- Caroline'\''s response pattern: " + .response_pattern + "\n" +
  "- Target: `" + .target_path + "`\n" +
  "- See the diff for the proposed prose."
) | join("\n\n")' "$CLUSTERS")
WEEK_OF=$(jq -r '.week_of' "$CLUSTERS")
CLUSTER_COUNT=$(jq -r '.clusters | length' "$CLUSTERS")

sed -e "s/{{WEEK_OF}}/$WEEK_OF/g" \
    -e "s/{{CLUSTER_COUNT}}/$CLUSTER_COUNT/g" \
    "$SCRIPT_DIR/../references/pr-template.md" \
  | awk -v block="$CLUSTERS_BLOCK" '{gsub(/\{\{CLUSTERS_BLOCK\}\}/, block); print}' \
  | "$SCRIPT_DIR/redact-output.sh" \
  > "$PR_BODY_FILE"

git push -u origin "$AUTO_BRANCH" >/dev/null 2>&1 || true

PR_URL=$(gh pr create \
  --title "chore(support): Caroline KB updates from week of $TODAY" \
  --body-file "$PR_BODY_FILE" \
  --reviewer nicksollazzo \
  --base "$BASE_BRANCH" \
  --head "$AUTO_BRANCH")

rm -f "$PR_BODY_FILE"
echo "$PR_URL"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
chmod +x scripts/open-kb-pr.sh
bats scripts/tests/open-kb-pr.bats
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/operations/skills/muso-caroline-weekly-review/scripts/open-kb-pr.sh \
  workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/open-kb-pr.bats
git commit -m "feat(ops): open-kb-pr.sh — ONE PR per week aggregating all clusters

Captures BASE_BRANCH up front. Validate-clusters gate before touching
files. Python in-place rewrite for multi-line safety. Runs
.githooks/pre-commit before committing. Safe-restore sequence on any
failure: reset --hard + clean -fd + checkout base + delete auto branch.
PR body piped through redact-output.sh defensively. Reviewer: nicksollazzo.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 10: Cron entry in `cron-jobs.json`

**Files:**
- Modify: `cron-jobs.json`

- [ ] **Step 1: Add the cron entry**

Append to the `jobs` array in `cron-jobs.json`:

```json
{
  "id": "GENERATE_UUID_HERE",
  "agentId": "operations",
  "name": "caroline-weekly-review",
  "description": "Weekly Caroline review — 7d Intercom grade across voice/tools/KB/sentiment, post to #cs_chats, open PR for repeated KB gaps. Lands disabled — manual shadow-channel run required before flipping enabled.",
  "enabled": false,
  "createdAtMs": GENERATE_NOW_MS,
  "updatedAtMs": GENERATE_NOW_MS,
  "schedule": {
    "kind": "cron",
    "expr": "0 9 * * 1",
    "tz": "Europe/Rome"
  },
  "sessionTarget": "main",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "Run the muso-caroline-weekly-review skill. Window: last 7 days. Return the final review text as your final assistant message — do NOT post to Slack directly; the cron runner will deliver it to #cs_chats.",
    "model": "openrouter/anthropic/claude-opus-4.7",
    "fallbacks": ["openrouter/anthropic/claude-sonnet-4-6"],
    "thinking": "high",
    "timeoutSeconds": 1500
  },
  "delivery": {
    "mode": "announce",
    "channel": "slack",
    "to": "C0ANM0PN9L5",
    "bestEffort": true
  },
  "state": {
    "consecutiveErrors": 0
  }
}
```

Generate the UUID with `uuidgen | tr A-Z a-z` and replace `GENERATE_NOW_MS` with `node -e 'console.log(Date.now())'`. Both values are inert because `enabled: false`.

- [ ] **Step 2: Validate JSON**

```bash
python3 -m json.tool cron-jobs.json >/dev/null && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add cron-jobs.json
git commit -m "feat(cron): add caroline-weekly-review cron entry (disabled)

agentId=operations, sessionTarget=main, delivery=announce to C0ANM0PN9L5.
Schedule 0 9 * * 1 Europe/Rome. Disabled until manual shadow-channel run
proves the main+announce shape works (rollout step 4 of the spec); falls
back to sessionTarget=isolated if the proof fails.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 11: PR

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feat/caroline-weekly-review
gh pr create \
  --title "feat(ops): Caroline weekly review cron (disabled, prereq-gated)" \
  --body-file - <<'EOF'
## Summary

Adds a Monday operations cron that grades the last 7 days of Caroline's Intercom conversations and posts to #cs_chats (C0ANM0PN9L5). Optionally opens one PR against `workspaces/support/reference/*.md` when a KB gap repeats across N>=3 unique contacts.

Lands `enabled: false`. The cron-shape proof (sessionTarget=main + announce delivery has no recorded successful run) is the rollout gate — manual `openclaw cron run --profile main` against a shadow channel must succeed before flipping enabled.

## Architecture

- New skill `workspaces/operations/skills/muso-caroline-weekly-review/`
- 9 deterministic bash scripts (preflight, fetch x2, redact x2, cluster, validate, open-kb-pr) + bats coverage
- LLM grading is done by the agent in-turn; scripts never call Slack
- Cron `announce` delivery is the only Slack path (no double-post)
- Dimension B (tool-usage grading) is prereq-gated on `ctx.conversationId` plumbing into the openclaw tool ctx — skipped, not faked, if absent

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-14-caroline-weekly-review-design.md`
- Plan: `docs/superpowers/plans/2026-05-14-caroline-weekly-review.md`

## Test plan

- [x] All bats tests pass (`bats workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/*.bats`)
- [x] `python3 -m json.tool cron-jobs.json` succeeds
- [ ] **Pre-merge**: Aaron / Nick review architecture
- [ ] **Pre-enable**: manual `openclaw cron run caroline-weekly-review --profile main` with `OPS_CAROLINE_REVIEW_SLACK_CHANNEL=<shadow>` proves main+announce shape (rollout gate)
- [ ] **Pre-enable**: prereq PR (ctx.conversationId plumbing into support-tools) landed, or accept Dimension B skip
- [ ] **Week 1 after enable**: review the first run's Slack output in #cs_chats before unsetting `OPS_CAROLINE_REVIEW_PR_DISABLE`

## Rollback

`enabled: false` is the default; flipping back disables. Skill files are isolated and unused if cron is disabled.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

---

## Self-Review

I checked the plan against the spec and these are the resolved spec-to-task mappings:

| Spec section | Task(s) |
|---|---|
| Cron entry shape | Task 10 |
| Skeleton (SKILL.md, references, helpers) | Task 1 |
| Phase 0 preflight (token, gh, git clean, journal, channel env, botAdminId, search-field test, tool-ctx probe) | Task 6 |
| Phase 1 fetch-conversations (Caroline filter, pagination, Retry-After, FILTER_MODE) | Task 7 |
| Phase 1 fetch-audit (leak audit + tool-call join) | Task 8 |
| Phase 1 redact (pre-LLM scrub) | Task 2 |
| Phase 2 cluster sizing (contact_id dedup) | Task 4 |
| Phase 3 validate (source-ID, path realpath, voice blacklist) | Task 5 |
| Phase 3 open-kb-pr (one PR, safe-restore, reviewer) | Task 9 |
| Final-output redaction gate | Task 3 |
| `OPS_CAROLINE_REVIEW_PR_DISABLE` honored | Documented in SKILL.md (Task 1) and consumed implicitly by the agent in Phase 3; no separate task needed |
| Rollout gate (manual shadow-channel run, prereq PR) | Documented in PR body (Task 11) and SKILL.md (Task 1); not code |
| `OPS_CAROLINE_REVIEW_SLACK_CHANNEL` | Task 6 (preflight) |

No placeholders, no "TBD", no "similar to Task N" — every code step has the actual code. Type/method-name consistency check: every script invocation matches its signature (e.g. `validate-clusters.sh <clusters.json> <conversations.jsonl> <repo_root>` is used identically in `open-kb-pr.sh`). `WORKDIR`, `CAROLINE_BOT_ADMIN_ID`, `FILTER_MODE`, `CV_TOOL_CTX_CONVERSATION_ID` are exported in `preflight.sh` and consumed by `fetch-conversations.sh` and `fetch-audit.sh` under the same names.
