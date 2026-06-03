# Caroline Weekly Review — Design

**Date:** 2026-05-14
**Status:** approved (Nick, 2026-05-14); revised with Clio review 2026-05-14
**Owner:** operations agent (cron-triggered)

> **Drift note (2026-05-26, PR #287 review):** This spec is historical. Two
> env vars referenced below have been removed during PR #287 review:
> `OPS_CAROLINE_REVIEW_SLACK_CHANNEL` (deleted — channel is driven by the
> cron entry's `delivery.to` field) and `OPS_CAROLINE_REVIEW_PR_DISABLE`
> (inverted to opt-in `OPS_CAROLINE_REVIEW_PR_OPEN`). SKILL.md is canonical
> for current behavior.
>
> **Update (2026-06-01, codex switch):** the cron's `payload.model` moved from
> `claude-opus-4.7` → codex `openai/gpt-5.5` (thinking `high`, fallback
> `claude-4.6-sonnet-20260217`) and `sessionTarget` `main` → `isolated`, to
> match the operations agent's other codex crons (`credit-verification-batch-4h`,
> `daily-dispute-handler`). The Architecture JSON snippet (§1) and §6 rollout
> prose below are historical; `cron-jobs.json` is canonical for model/session.
> `isolated + announce` is the already-proven shape (used by
> `codex-usage-report-*`), so the §6 proof gate now validates that shape —
> fall back to `sessionTarget: main` only if the isolated session is found to
> lack `gh`/`git`/`journalctl` host access.
**Review owner:** Nick (`<@U0AL36NADEY>`)

## Revision log

- 2026-05-14: Clio sanity-check #1. Accepted: duplicate-Slack fix (skill
  returns text, cron delivers), Caroline admin_id filter, conversation_id
  join key as Dimension-B prereq, one-PR-per-week aggregation, mktemp
  hardening, redaction before LLM grading, Intercom-Version + pagination
  + Retry-After, N≥3 unique customer emails, source-ID validation, realpath
  canonicalization, preflight script, 0–5 scoring, all bats additions.
  Initial pushback on cron-shape claim citing `credit-verification-batch-4h`
  was **overstated** — that cron has `lastRunStatus: null` and has never
  successfully fired. Corrected in revision #2.
- 2026-05-14: Clio sanity-check #2. **Walked back the cron-shape proof**:
  no `sessionTarget: main` cron with `delivery.mode: announce` has actually
  succeeded in recorded history; all confirmed-`ok` crons use
  `sessionTarget: isolated`. Manual-run-against-shadow-channel gate is now
  mandatory before enabling. Accepted: use `botAdminId` from intercom
  plugin config (confirmed in `plugins/intercom/src/types.ts:110`) not
  email-match; preflight-test the conversation-search field, fall back to
  broader fetch + post-filter; tool-call ctx plumbing prereq is more than
  "log it" — `plugins/support-tools/src/tools/*` don't read ctx today, so
  the prereq PR must expose `conversation_id` to tool ctx first;
  `OPS_CAROLINE_REVIEW_SLACK_CHANNEL` is the canonical env name;
  `contact_id` is the primary dedup key, `customer_email` is fallback;
  severity recalibrated (voice blacklist alone is P2, not P0); branch
  restore must `git reset --hard` + `git clean -fd` + checkout-base before
  delete; final-output redaction gate before delivery.

## Problem

Caroline (the support agent) replies to live Intercom traffic 24/7. We have no
recurring loop that asks "did Caroline behave well this week?" Her KB
(`workspaces/support/`) is hand-edited, drift between SOUL.md and runtime
behavior has already cost us twice (PR #270 found the `support-tools` plugin
had never loaded in prod; PR #213 found 58 sites of `/w/admin` route drift).
PR #270 just shipped major behavioral changes (`profile_status`,
`analytics-followup` ticket flow, tool-leak sanitizer) and we have no
regression signal except waiting for a customer to complain.

We want a Monday morning ritual: review the last 7 days of Caroline
conversations, surface what she did well and badly, and let the KB evolve from
observed gaps instead of vibes.

## Goal

Every Monday at 09:00 Europe/Rome, the operations agent:

1. Pulls 7 days of Caroline's Intercom conversations.
2. Grades them across 4 dimensions: voice/leak, tool usage/escalation, KB
   gaps, customer sentiment. Also surfaces a "good catches" section so the
   review isn't only negative.
3. Posts a scored review to Slack `#cs_chats` (`C0ANM0PN9L5`), tagging
   Nick (`<@U0AL36NADEY>`).
4. If a KB gap repeats (N≥3 customers, same topic) and the proposed edit is
   confined to `workspaces/support/reference/*.md`, opens a PR with Nick as
   reviewer. PR body cites the conversation IDs that triggered the change.

Non-goals: real-time review, auto-editing SOUL.md / TOOLS.md / skills, and
extending the pattern to other agents (Clio, Fede CMO) — those are separate
designs.

## Architecture

### 1. Cron entry (`cron-jobs.json`)

```json
{
  "agentId": "operations",
  "name": "caroline-weekly-review",
  "description": "Weekly Caroline review — 7d Intercom grade across voice/tools/KB/sentiment, post to #cs_chats, open PR for repeated KB gaps",
  "enabled": false,
  "schedule": { "kind": "cron", "expr": "0 9 * * 1", "tz": "Europe/Rome" },
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
  }
}
```

Notes:
- `sessionTarget: main` because the skill needs git, `gh`, `journalctl`, and
  `$MUSOAI_INTERCOM_TOKEN` from the host env. **Pattern is plausible but
  NOT yet proven**: `credit-verification-batch-4h` declares the same shape
  but has `lastRunStatus: null` (never fired successfully); no
  `sessionTarget: main` + `delivery.mode: announce` cron has a confirmed
  `ok` run in the recorded history. The mandatory manual-run-against-
  shadow-channel step in §6 is the proof gate. If `main` + `announce` turns
  out to be broken, the fallback is the `cmo-eod-briefing` pattern
  (sessionTarget: isolated) with all required host env shimmed in — that
  pattern HAS recorded successful runs.
- **Skill never posts to Slack directly.** The skill returns the final review
  text as its last assistant message; the cron runner delivers it via
  `announce`. This avoids the double-post failure mode. Matches the pattern
  established by `cmo-eod-briefing` and `daily-churned-campaign-refresh`.
- Model: Opus 4.7 because grading is a thinking task; Sonnet 4.6 fallback.
  Avoided Fireworks/glm-5p1/kimi-k2p6 per `reference_openclaw_cron_bugs.md`
  (both unsafe for customer-adjacent work).
- Timeout 1500s — fetch + grade + optional PR; matches the credit-verification
  cron's 1800s budget for similar complexity.
- Schedule `0 9 * * 1` Europe/Rome — Monday 9am Rome lands 8am UTC summer /
  9am UTC winter; ahead of Nick's day, fresh in Slack when he opens it.
- Lands `enabled: false`. Rollout (§6) flips it.

### 2. New skill: `workspaces/operations/skills/muso-caroline-weekly-review/`

```
SKILL.md                 # workflow contract (loaded at agent turn)
scripts/
  preflight.sh           # token, jq, gh, git clean, branch absent, journal, channel env, Intercom 200, botAdminId resolve, search-field test
  fetch-conversations.sh # Intercom search + transcript pull (7d window), assignee-or-post-filter mode
  fetch-audit.sh         # journalctl grep for sanitizer + tool-leak audit, plus tool-call join via conversation_id (Dimension B only)
  redact.sh              # email/last-name scrub for LLM input; first names preserved
  redact-output.sh       # final-output mechanical scrub before delivery (Slack body + PR body)
  cluster-questions.sh   # group customer questions by topic; dedup by unique contact_id (email fallback)
  validate-clusters.sh   # source-ID + unique-contact-count + path-allowlist (realpath) + voice-blacklist gates
  open-kb-pr.sh          # ONE branch + ONE commit + ONE PR per week, taking a JSON array of approved clusters
  tests/
    preflight.bats
    fetch-conversations.bats   # pagination, Retry-After, Caroline admin_id filter
    cluster-questions.bats     # dedup by customer_email, N>=3 unique
    validate-clusters.bats     # hallucinated IDs rejected, path traversal rejected
    redact.bats                # emails + last names scrubbed in all sections including "good catches"
    open-kb-pr.bats            # MUST PATH-stub gh, git, openclaw per feedback_bats_must_stub_openclaw;
                               # no-PR-when-dirty; one PR for multiple clusters
references/
  grading-rubric.md      # the 4 dimensions, 0-5 scores, P0/P1/P2 severity, "good catches" format
  pr-template.md         # the exact PR body template (evidence required, multi-cluster)
```

### 3. Workflow phases

#### Phase 0 — Preflight (`scripts/preflight.sh`)

Fail loud BEFORE grading if any of:
- `$MUSOAI_INTERCOM_TOKEN` missing or token endpoint returns non-200
- `jq`, `gh`, `git` not on PATH
- `gh auth status` fails
- Working tree dirty (would break PR creation)
- Branch `auto/caroline-kb-review-YYYY-MM-DD` already exists (re-run on
  same day must be intentional)
- `journalctl -u openclaw-gateway-edge.service --since "1 minute ago"` errors
  (permission/unit missing)
- `$OPS_CAROLINE_REVIEW_SLACK_CHANNEL` resolves (defaults to `C0ANM0PN9L5`)
- **Caroline `botAdminId` resolution**: read `botAdminId` directly from the
  intercom plugin config (`plugins/intercom/src/types.ts:110` defines the
  field; `plugins/intercom/src/config.ts:87` throws if missing). Confirm
  it exists in `/admins` via `GET https://api.intercom.io/admins` with
  `Intercom-Version: 2.11`. Email matching is NOT a fallback — the bot's
  email is unstable; `botAdminId` is the authoritative key.
- **Conversation-search filter test**: send a smoke `conversations/search`
  with `admin_assignee_id == <botAdminId>` and `per_page=1`; if Intercom
  rejects the field (HTTP 400 or empty `data.conversations` despite known
  activity), fall back to the broader `updated_at > now-7d` fetch with
  post-filter on `author.id == botAdminId`. Record which mode is in use
  so the Slack post can note `(filter mode: assignee | post-filter)`.

Exit with a clear error code; the skill catches and posts a failure summary
via the cron's announce delivery (not via direct Slack send).

#### Phase 1 — Fetch (deterministic, scripted)

`scripts/fetch-conversations.sh`:
- `POST https://api.intercom.io/conversations/search` with
  `Intercom-Version: 2.11` header.
- **Filter mode selected at preflight** (see Phase 0 conversation-search
  filter test):
  - `assignee` mode: `updated_at > now-7d` AND
    `admin_assignee_id = <botAdminId>`. Smaller fetch.
  - `post-filter` mode: `updated_at > now-7d` only; filter Caroline-
    authored conversations post-fetch. Larger fetch but guaranteed correct.
- Pagination: follow `pages.next.starting_after` until exhausted (`per_page=150`).
- For each conversation, `GET /conversations/{id}?display_as=plaintext`.
- Filter again post-fetch (both modes): keep only conversations where ≥1
  outbound part has `author.type == "admin"` AND `author.id == <botAdminId>`.
  In `assignee` mode this is belt-and-braces; in `post-filter` mode it is
  the primary filter.
- 429 handling: honor the `Retry-After` header; if absent fall back to
  exponential backoff 1s/2s/4s (max 3 retries). On final failure: post a
  "rate-limited, partial sample" warning in the review.
- Cap at **200 conversations** for grading. If the week exceeds 200, take:
  - All conversations with explicit-frustration regex hits (see Phase 2)
  - All conversations containing a `[intercom:tool-leak]` or
    `[intercom:email-leak]` audit line
  - Random sample to fill remaining slots
- Output: `${WORKDIR}/conversations.jsonl` — one conversation per line with
  `{ id, contact_id, customer_email, customer_first_name, parts: [...],
  started_at, closed_at }`. `WORKDIR` is `mktemp -d` with `chmod 700` and a
  trap to remove on exit. `contact_id` is the Intercom contact id and is
  the **primary dedup key** for cluster sizing (see Dimension C); blank or
  null emails would otherwise collapse unrelated contacts into one
  "customer".

`scripts/fetch-audit.sh`:
- `journalctl -u openclaw-gateway-edge.service --since "7 days ago" \
   | grep -E 'intercom:tool-leak|intercom:email-leak'`
- Plus support-agent tool calls from the **edge** gateway session logs —
  Caroline runs on edge per PR #270. Per
  `reference_openclaw_exec_tool_name.md` the shell tool is `exec`; filter
  accordingly when scanning. Pull `profile_status`, `create_ticket`,
  `profile_lookup`, `credits_search`, `subscription_status` call records.
- **Tool-call ↔ conversation join key (prereq)**: verified at spec time —
  `plugins/support-tools/src/tools/*.ts` consume `ctx.sessionId` only;
  `conversation_id` is NOT in the tool plugin ctx today. Intercom dispatches
  the conversation as session identity, but the tool layer never sees the
  raw `conversation_id`. Without a join key, Dimension B grading degrades
  to grep-by-vibes.
  **Prereq PR (two-part, must land before this cron's auto-PR rollout)**:
  1. Extend the openclaw plugin-ctx interface to expose `conversation_id`
     (or Intercom peer id) to tool callbacks — this is the part that's
     more than a logging change; it requires the intercom plugin's
     `dispatch_to_agent` path to propagate the id into the tool-invocation
     ctx the runtime hands to support-tools.
  2. Update `plugins/support-tools/src/index.ts` (and per-tool files) to
     read `ctx.conversationId` and emit it on every tool log line.
  Tracked as a separate PR. If the prereq slips, Dimension B is **omitted**
  from the review (replaced with a "skipped: join-key prereq pending" line)
  rather than fabricated.
- Output: `${WORKDIR}/audit.jsonl`.

`scripts/redact.sh` (runs over `conversations.jsonl` before LLM grading):
- Replace customer emails with `<email>` everywhere they appear in transcript
  bodies (not just the `customer_email` field).
- Replace `customer_last_name` instances inside transcript bodies with the
  first initial; keep `customer_first_name` for sentiment grading (rude tone
  often correlates with the customer's emotional register; stripping the
  first name loses signal).
- Conversation IDs, timestamps, role labels, and message text remain.
- Output: `${WORKDIR}/conversations.redacted.jsonl`. The LLM grader reads
  only the redacted file.

#### Phase 2 — Grade (LLM-driven, structured)

The agent loads both jsonl files and grades against `grading-rubric.md`:

Every dimension gets a 0–5 score plus severity flags (P0 / P1 / P2). P0 in
any dimension forces the Slack headline.

- **P0**: any `[intercom:tool-leak]` / `[intercom:email-leak]` audit line
  in window, OR any regression-watch pattern from Dimension B (the
  analytics→email/support loop that PR #270 killed).
- **P1**: wrong escalation, wrong actionType/tier, missed required
  `profile_status` call on an analytics/streams conversation, or refund
  3-gate skipped.
- **P2**: voice blacklist hit ("Great question", em-dash, "investigate",
  apologies-for-analytics), KB gap cluster, sentiment issue. Tone lint is
  not P0 — only a tone slip that also triggers a leak or support-loop
  rolls up to P0 via its Dimension B/leak finding.

**Dimension A — Voice + leak audit.**
Mechanical scans first:
- `grep '—'` (em-dash) in outbound bodies → count + cite conversation IDs.
- Phrase blacklist: "Great question", "I understand your frustration",
  "investigate", apologies-for-analytics ("sorry the analytics are
  delayed", "sorry for the latency").
- Audit-line count from `audit.jsonl`. Any non-zero is the **top-line of
  the Slack post** — these are PR #270 regression signals.
- Score: 5 if zero leaks AND zero blacklist hits; -1 per blacklist hit;
  floor at 0. Any P0 hit displayed regardless of score.

**Dimension B — Tool usage + escalation hygiene.** (Skipped if join-key
prereq not landed; see Phase 1.)
- For each conversation that mentions "analytics", "streams", "data",
  "updating": did Caroline call `profile_status` (joined by
  `conversation_id`)? If not, flag P1.
- For each `create_ticket` call: correct `actionType` + tier? Match
  against `workspaces/support/TOOLS.md` actionType table.
- For each refund mention: was the refund-retention 3-gate run before
  ticket creation?
- Regression watch: any of these patterns in outbound bodies:
  - `email support@muso\.ai`
  - `(contact|reach out to|email) support`
  - PR #270 explicitly killed the analytics→email loop; resurfacing is P0.
- Score: 5 if all expected `profile_status` calls fired AND no escalation
  mismatches AND no regression pattern.

**Dimension C — KB gaps / repeated questions.**
- Cluster customer first-messages by topic (LLM does the clustering with
  the redacted conversation jsonl; topic = short noun phrase like "FLAC
  export", "missing co-writer credit", "Spotify analytics frequency").
- Cluster sizing rule: **N = unique `contact_id`** (primary), falling
  back to `customer_email` only when `contact_id` is missing. Counting by
  email alone collapses blank/null-email contacts into a single bogus
  "customer". One frustrated contact with three threads counts as N=1.
- For each cluster N≥3 (unique customers): did Caroline answer from
  `reference/*.md` or improvise / punt? If improvise/punt → KB-gap
  candidate.
- Output the cluster with: topic, unique-customer-count, conversation IDs,
  Caroline's response pattern, suggested `reference/*.md` insertion (which
  file, where, exact prose).
- Score: 5 if zero gaps; -1 per gap; floor at 0. All gaps are P2.

**Dimension D — Customer sentiment.**
- Per-conversation label: `resolved` / `escalated` / `frustrated` /
  `ghosted`.
- Explicit-frustration pattern: "you're a bot", "are you actually
  checking", "this is useless", "human please", repeat-question after
  Caroline's reply.
- Per-week counts + the top 3 frustration conversations cited (P2 each).
- Score: 5 - frustration_count, floor at 0.

**"Good catches" section.**
- 2–3 conversations where Caroline did something particularly well: nailed
  a tricky pushback, deflected an over-eager refund correctly, called
  `profile_status` and grounded the answer in real data. Cite the
  conversation IDs and quote the good line.
- Purpose: keep the review balanced and give us a positive reference for
  voice-tuning, not just regression hunting.

#### Phase 3 — Output

**Always — Slack delivery via cron `announce`** to `C0ANM0PN9L5` (skill returns
this text as its final assistant message; cron delivers it — never both):

```
<@U0AL36NADEY> — Caroline weekly review, week of <YYYY-MM-DD>

*Headline:* <P0_count> P0 / <P1_count> P1 / <P2_count> P2
Voice: <0-5> | Tools: <0-5 or "skipped: join-key prereq pending"> | KB: <0-5> | Sentiment: <0-5>

*Voice + leak audit* (Voice <0-5>)
• Leak audit lines: <n> — top-line if non-zero (P0)
• Em-dashes: <n>, blacklist hits: <n>
• ...

*Tool usage + escalation hygiene* (Tools <0-5> or skipped)
• Missed profile_status calls: <n> (P1 each)
• Wrong-tier tickets: <n>
• Regression pattern hits: <n> (P0 each)
• ...

*KB gaps / repeated questions* (KB <0-5>)
• <topic-1>: <N> unique customers — conv IDs: <…> (P2)
• ...

*Customer sentiment* (Sentiment <0-5>)
• <resolved> resolved / <escalated> escalated / <frustrated> frustrated / <ghosted> ghosted
• Top frustration: <conv_id> — "<quote>" (P2)

*Good catches*
• <conv_id>: "<quote>"
• ...

*Auto-PR:* <link or "none this week — no KB gap met N>=3 unique-customer bar">
```

PII redaction is applied **twice**:
1. **Pre-LLM** (`scripts/redact.sh`) — strips emails and last names from
   `conversations.jsonl` before grading; first names preserved for tone.
2. **Final-output gate** — every Slack delivery body AND every PR body
   passes through `scripts/redact-output.sh` immediately before delivery.
   The LLM can reintroduce PII from summaries even when its input was
   clean (and will), so a mechanical scrub at the wire is mandatory.
   Patterns scrubbed: email regex
   `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}` → `<email>`; phone
   patterns (E.164 + common formats) → `<phone>`; Stripe customer ids
   (`cus_…`), payment intent ids (`pi_…`), charge ids (`ch_…`) → `<stripe_id>`.
   Bats-tested. Conversation IDs (internal) and `contact_id` are allow-listed
   through (they're internal-only and the review is unusable without them).

**Conditional — Auto-PR (one PR per week, aggregating all approved clusters).**

The agent assembles ALL KB-gap clusters that meet N≥3 unique customers into
a single JSON array and calls `scripts/open-kb-pr.sh <approved.json>`:

```json
{
  "week_of": "2026-05-12",
  "clusters": [
    {
      "topic": "FLAC export",
      "unique_customers": 4,
      "conversation_ids": ["3781..", "3812..", "3855..", "3901.."],
      "target_path": "workspaces/support/reference/common-issues.md",
      "anchor": "## Audio file export",
      "insertion": "...exact prose..."
    },
    ...
  ]
}
```

The script:

1. **Validate-clusters gate** (`scripts/validate-clusters.sh`, mechanical):
   - Every `conversation_ids[]` entry exists in `${WORKDIR}/conversations.jsonl`
     (no hallucinated IDs).
   - `unique_customers == nunique(customer_email for id in conversation_ids)`.
   - `target_path` matches regex `^workspaces/support/reference/[^/]+\.md$`
     AND `realpath --relative-to=$REPO_ROOT $target_path` still matches the
     same regex (defends against symlink/`..` traversal).
   - `insertion` contains no em-dash, no entries from the voice blacklist.
   - Reject any cluster that fails. If all clusters fail → no PR; report in
     Slack.
2. **Worktree clean check**: `git diff --quiet && git diff --cached --quiet`
   or abort.
3. **Single branch** `auto/caroline-kb-review-YYYY-MM-DD`. If it already
   exists, abort (preflight should have caught this).
4. Apply edits for ALL approved clusters as a Python in-place rewrite (not
   sed — multi-line content). Each cluster's insertion goes under its
   declared anchor in its target file.
5. Run `bash .githooks/pre-commit` (hydra's hand-rolled hook, not the
   `pre-commit` framework). If it fails, run the safe-restore sequence
   (see below) and abort; include the hook output in the Slack post.

   **Safe-restore sequence** (used by every abort path after edits are
   applied): capture `BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)` at
   the start of `open-kb-pr.sh` (must be the base branch the cron ran on,
   not the auto branch). After the auto branch is created, on any abort:
   ```
   git reset --hard
   git clean -fd
   git checkout "$BASE_BRANCH"
   git branch -D auto/caroline-kb-review-<date>
   ```
   `git checkout -- .` alone leaves untracked files and won't move off the
   auto branch; the sequence above guarantees a clean return to base.
6. `git commit` with `Co-Authored-By: Caroline Weekly Review <ops@muso.ai>`,
   commit body lists every cluster topic + cited conversation IDs.
7. `gh pr create` with title `chore(support): Caroline KB updates from
   week of YYYY-MM-DD`, reviewer `nicksollazzo`, body from
   `pr-template.md` (one PR body summarising N clusters).

PR body template (`references/pr-template.md`):

```
## Summary

Weekly Caroline review for <YYYY-MM-DD> surfaced <N> KB-gap cluster(s)
with N≥3 customer evidence. This PR proposes the edits.

## Clusters

### <topic-1>
- Customers: <N>
- Conversation IDs: <id1>, <id2>, <id3>, ...
- Caroline's response pattern: <improvise|punt|email-loop|...>
- Proposed edit: `workspaces/support/reference/<file>.md` — see diff

### <topic-2>
...

## Out of scope for auto-PR

This PR ONLY edits `workspaces/support/reference/*.md`. SOUL.md, TOOLS.md,
and skills/*/SKILL.md changes are listed in the Slack post for human
review (`C0ANM0PN9L5`).

## Verification

- [x] pre-commit hooks pass (em-dash, etc.)
- [ ] Nick: review for voice + accuracy
- [ ] Nick: confirm conversation IDs back the proposed edits
```

### 4. Error handling

| Failure | Action |
|---|---|
| Preflight fails | Skill returns a "preflight failed: <reason>" message; cron `announce` delivers it. No grading attempted. |
| Intercom 429 | Honor `Retry-After` header if present; otherwise exponential backoff 1s/2s/4s (max 3). On final failure: include "rate-limited, partial sample" warning in the headline. |
| Intercom 5xx after retry | Skill returns failure summary; cron delivers it. Do NOT silently NO_REPLY. |
| Caroline admin_id resolution fails | Same as preflight fail. |
| 0 conversations Caroline touched in window | Skill returns "No Caroline conversations to review this week." (silence on Monday would itself be alarming) |
| `gh pr create` fails | Include the full review in the returned text + the proposed diff inline as a code block + the gh error. |
| `$MUSOAI_INTERCOM_TOKEN` expired | Same as 5xx — fail loud via returned text. |
| Hallucinated conversation_id in cluster | Cluster rejected by `validate-clusters.sh`; reported in Slack as "cluster <topic> rejected: ID <id> not in fetched set". |
| Voice blacklist hit in proposed edit | Cluster rejected by `validate-clusters.sh`; reported in Slack as "cluster <topic> rejected: voice violation in proposed prose". |
| Pre-commit hook fails after edits applied | Restore branch (`git checkout -- .` + `git branch -D auto/...`); include hook output in Slack. |
| Worktree dirty at run time | Preflight fails BEFORE any fetch. |

Per `feedback_llm_instruction_insufficient.md`: prose-level "don't do X"
rules in SKILL.md are not enforcement. The em-dash check and target-path
allowlist are enforced **mechanically in `scripts/open-kb-pr.sh`**, not by
the LLM agent. The agent can propose anything; the script gates what
becomes a PR.

### 5. Testing

Bats tests (all **MUST PATH-stub `openclaw`, `gh`, `git`, `curl`** per
`feedback_bats_must_stub_openclaw.md`):

- `preflight.bats` — missing token, missing tools, dirty worktree, branch
  already exists, channel env unset, admin_id resolution failure
- `fetch-conversations.bats` — pagination through `pages.next.starting_after`,
  429 `Retry-After` honored, exponential fallback when header absent,
  Caroline `admin_assignee_id` filter applied, post-fetch
  `author.id == caroline` belt-and-braces filter
- `cluster-questions.bats` — clustering correctness; **deduplication by
  `customer_email`** (same person with 3 threads = N=1)
- `validate-clusters.bats` — hallucinated conversation_id rejected;
  unique-contact-count mismatch rejected; contact_id-vs-email-fallback
  correctness; non-`reference/*.md` path rejected; path traversal via
  `..` rejected; symlink-escape rejected (realpath check); voice
  blacklist hit rejected
- `redact.bats` — pre-LLM scrub: emails + last names; first names
  preserved
- `redact-output.bats` — final-output scrub: emails, phones, Stripe ids
  scrubbed from Slack body + PR body; conversation_ids + contact_ids
  allow-listed; tests cover LLM-reintroduced PII (an explicit fixture
  where the LLM's grading summary mentions a customer email even though
  input was redacted)
- `open-kb-pr.bats` — one PR for multiple clusters (not per-cluster); no
  PR when worktree dirty; pre-commit-hook failure triggers full
  safe-restore sequence (reset --hard + clean -fd + checkout base +
  delete auto branch); commit body lists all cluster topics; reviewer
  set to `nicksollazzo`; capture-and-restore-base-branch on abort works
  regardless of which branch the cron started on

Rollout envs:

- `OPS_CAROLINE_REVIEW_PR_DISABLE=1` — skill runs everything except the
  `gh pr create` step. Skill returns review text including a "would-have-PRd"
  section.
- `OPS_CAROLINE_REVIEW_SLACK_CHANNEL=<test_channel>` — preflight reads this
  (defaults to `C0ANM0PN9L5`). The cron `delivery.to` field can ALSO be
  overridden at the cron-config level for the first manual trigger; both
  paths exist for flexibility but the env var is the canonical knob.

### 6. Rollout

1. **Prereq PR (separate, must land first)**: plumb `conversation_id` into
   the openclaw tool-plugin ctx, then have `plugins/support-tools/src/*`
   read `ctx.conversationId` and emit it on every tool log line. This is
   two changes (runtime ctx + support-tools consumer), not just a logging
   change. Without it, Dimension B is skipped on every run.
2. Land this spec + plan + skill with `OPS_CAROLINE_REVIEW_PR_DISABLE=1`.
3. Add the cron entry to `cron-jobs.json` with `enabled: false`.
4. **Cron-shape proof gate (mandatory)**: manual trigger once via
   `openclaw cron run caroline-weekly-review --profile main`. Verify the
   cron run record shows `lastRunStatus: "ok"` AND `lastDelivered: true`
   AND the message actually arrives in the shadow channel
   (`OPS_CAROLINE_REVIEW_SLACK_CHANNEL=<test_channel>`). Only after this
   passes is the `sessionTarget: main` + `announce` shape considered
   proven. If it fails, fall back to `sessionTarget: isolated` + host-env
   shim, matching `cmo-eod-briefing`.
5. Flip `enabled: true`. First Monday in #cs_chats: Slack-only (PR
   disabled via `OPS_CAROLINE_REVIEW_PR_DISABLE=1`).
6. Second Monday: Nick reviews the previous week's recommendations. If
   quality is good, unset `OPS_CAROLINE_REVIEW_PR_DISABLE` for week 3.

### 7. Open questions resolved

- **Tag**: Nick (`<@U0AL36NADEY>`), not Jan. (Per Nick 2026-05-14.)
- **"Good catches" section**: included. (Per Nick 2026-05-14.)
- **Auto-merge after N days**: no. PRs sit until Nick merges or closes.

## Risk register

| Risk | Mitigation |
|---|---|
| Auto-PR proposes a contradiction with SOUL.md | Path allowlist forbids SOUL.md edits. Reference/*.md is meant to expand the FAQ surface, not redefine voice. |
| Auto-PR introduces an em-dash or voice violation | Mechanical scan in `open-kb-pr.sh` + repo pre-commit hook. Two layers. |
| LLM hallucinates conversation IDs in the PR body | PR body assembles citations from the cluster output, not free-form. Citations are conversation IDs from the fetched jsonl, not LLM-invented. |
| Intercom token rotation breaks the cron silently | Fail-loud post to `C0ANM0PN9L5` on auth error. No NO_REPLY path. |
| Sample cap (200) misses a real signal | Sampling prioritises explicit-frustration + leak-event conversations first, then random fill. If weekly volume regularly exceeds 200, revisit cap. |
| Customer PII in Slack post | Redaction runs before LLM grading AND before delivery; covers all sections including "good catches" quotes. Bats-tested. |
| Tool-call attribution false-positive | Without conversation_id join key, grep-by-vibes would invent correlations. Mitigated by making Dimension B prereq-gated; skipped (not faked) if the prereq PR hasn't landed. |
| Auto-PR collides with itself on re-run | Preflight aborts if `auto/caroline-kb-review-YYYY-MM-DD` already exists. Manual `--force` only via explicit env. |
| Temp files leak customer transcripts | `mktemp -d` + `chmod 700` + `umask 077` + exit trap remove `${WORKDIR}` on success and failure paths. |

## Out of scope

- Real-time review (this is weekly on purpose; faster cadence is a separate
  design)
- Auto-editing SOUL.md, TOOLS.md, skills/*/SKILL.md
- Extending to other agents (Clio, Fede CMO, devops bot) — same pattern would
  generalise; not in this scope
- Auto-merging the PR
- Cross-week trend tracking (week-over-week deltas) — could come later
