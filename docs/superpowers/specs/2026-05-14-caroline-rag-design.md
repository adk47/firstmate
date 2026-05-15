# Caroline RAG + analytics-escalation gap — design

**Date:** 2026-05-14
**Author:** Nick (with Claude)
**Status:** v2 — policy reversed mid-PR (see Revision History at end)
**Successor to:** [2026-05-11-caroline-analytics-handoff-design.md](2026-05-11-caroline-analytics-handoff-design.md) (PR #270, handoff plumbing)
**Related:** [2026-05-08-caroline-analytics-knowledge-base-design.md](2026-05-08-caroline-analytics-knowledge-base-design.md) (PR #269, KB rewrite)

> **POLICY FLIP MID-DOCUMENT — read this first.**
>
> Sections of this spec originally said the fix for the missed-escalation gap was to make `create_ticket` fire reliably on analytics pushback (Rule 2). **That policy was reversed 2026-05-14** after Nick + Aaron determined Caroline's analytics tickets were filling Jan's queue without any per-account follow-up actually happening — the implicit SLA promise ("you'll hear back in 2 business days") was effectively a lie that eroded trust faster than the original problem.
>
> The **final shipped policy** is in the new section "Final policy (v2)" further down. In short: **no `create_ticket` calls for analytics, no team-review promises, no "you'll hear back" SLAs.** When the customer pushes back, Caroline acknowledges honestly that there is no per-account fix or timeline, and offers a "message back in a couple of weeks and I'll re-check your profile" lane.
>
> Where you see "Rule 2", "concrete pushback → create_ticket", "analytics-followup ticket on pushback", "ticket-create rate should approach 75–100%", or any business-days SLA below — that is **historical analysis from the v1 doctrine**, retained as design evidence. **Do not act on those instructions.** The "Final policy (v2)" section at the bottom is the source of truth.

## Problem

PR #270 (merged 2026-05-11) gave Caroline the `create_ticket` tool and the `analytics-followup` ticket type. The analytics doctrine has lived as row #7 of `reference/common-issues.md` since PR #269 (2026-05-08).

Measurement over the 36 hours after PR #270 deployed (48 analytics-related sessions, post-2026-05-11 16:25 UTC):

| Metric | Result | Doctrine target |
|---|---|---|
| Punted to `support@muso.ai` | 0 / 48 | 0 (forbidden in doctrine) ✓ |
| Called `profile_status` before ticket | 100% of tickets | required first step ✓ |
| Customer accepted explanation → no ticket | ~10 / 48 (21%) | matches "if customer accepts, close out" ✓ |
| `create_ticket` fired | 26 / 48 (54%) | should fire on pushback |
| **Pushback detected but no `create_ticket` call** | **~12 / 48 (25%)** | **doctrine miss** |

The 25% miss has a consistent pattern: Caroline correctly identifies the issue, **says** "I'll flag this to the team" or equivalent, then **never calls `create_ticket`**. Examples in the sampled window:

- `cda2bd69` — "I'll flag your profile for the team to review" → no `create_ticket`
- `4975a170` — "needs review on our side" → no `create_ticket`
- `4d635a1c` — told user to log out and log back in (forbidden-spirit move) → no `create_ticket`
- `cfb0f2da` — user reported profile dropped from 60M to 0 streams → no `create_ticket`
- `4de64782` — user gave a concrete stuck number ("259,759,141") → no `create_ticket`

Two underlying causes:

1. **Intent–action gap.** Caroline produces escalation language ("I'll flag", "I'll send to engineering") but the tool call doesn't follow. The text and the tool call are not atomic.
2. **Doctrine discovery is on-demand.** `reference/common-issues.md` is read via the `read` tool only when Caroline decides to. In some of the missed sessions she never loaded the file at all — the doctrine that would have routed her to `create_ticket` was simply not in context.

Aaron's recent feedback (screenshots, 2026-05-14): customers feel jerked around by the chat-then-don't-forward pattern. His direction: chat less on analytics, forward immediately. Constraint from Nick: don't flood Jan with tickets; Caroline should still try to resolve where she can.

## Goal

1. Close the 25% pushback-without-ticket gap so Caroline's escalation language and tool calls are atomic.
2. Make doctrine retrieval mechanical: when a customer raises a topic with documented guidance, Caroline encounters that guidance on every turn without having to choose to read a file.
3. Build the structural pattern so future incidents (next platform outage, integration regression, etc.) can be deployed by editing one file — not by writing new skills or PRs to multiple places.

Expected outcome: ticket-create rate on analytics pushback approaches 100% (matching cases where the customer accepts the explanation continue to not produce tickets, preserving Jan's queue from venter-noise). Future incident narratives propagate to Caroline by editing one Aaron-owned file.

## Non-goals

- No Dreaming / autoCapture for Caroline. See "Why no Dreaming" below.
- No new issue-specific skills (`analytics-stuck-fast-track`, `spotify-broken-fast-track`, etc.). They drift and proliferate. The active-incidents file is the single source of transient narrative state.
- No changes to SOUL.md tone rules. They are working.
- No changes to the ClickUp custom-field plumbing. The empty Profile ID / Muso URL / Intercom Link fields on tickets are a known follow-up (see `project_support_tools_deploy.md`) and ship in a separate PR.
- No Caroline-side rewrite of how she talks to customers. Tone and personality are working; the gap is mechanical.

## Decision summary

| Decision | Choice | Why |
|---|---|---|
| Doctrine discovery | **Enable openclaw `memorySearch` + `autoRecall`** for the support agent | Retrieved chunks auto-inject pre-prompt; eliminates "she forgot to read the file" |
| Plugin slot | Use built-in `memory-core` (already default) | No new install; already occupies the slot |
| Embedding provider | **OpenAI `text-embedding-3-small`** (auto-priority 20) | Cheap (~$2–5/month at Caroline's volume), existing OPENAI key wiring, simpler than Voyage |
| Indexed content | **Read-only**: `/opt/hydra/workspaces/support/reference/*.md` | Static doctrine, safe to share across customers |
| Dreaming | **Disabled** | Four open upstream bugs (#63921 PII leak, #65374 cross-agent contamination, #65550 runaway loop, #66947 daily-file pollution); manual GDPR erasure; no customer-facing postmortems exist |
| autoCapture | **Disabled** | Persisting customer transcripts is cross-pollination risk for many-customer single-agent setup |
| Session scope | Keep `dmScope: per-channel-peer` (already set) | Per-conversation session isolation; lock via CI invariant |
| Memory store path | Per-agent path with `{agentId}` token | Prevents Caroline from reading ops/credit-verification memory |
| Closing the 25% gap | Add **Rule 1 (say-it=do-it)** and **Rule 2 (concrete pushback signals)** to `common-issues.md` row #7 | Two micro-rules cover all 12 sampled misses |
| Transient narratives | New file `reference/active-incidents.md`, Aaron-editable | One place to update when narrative shifts; deleted lines when incident resolves |

## Architecture

```
Customer message (via Intercom)
      │
      ▼
Edge gateway (openclaw 2026.5.5, support agent)
      │
      ├─► memorySearch.autoRecall:
      │     • embed message via OpenAI text-embedding-3-small
      │     • hybrid retrieve (vector + BM25) from qmd index
      │     • inject top-k chunks pre-prompt
      │
      ├─► autoCapture: OFF (no writes)
      ├─► dreaming.enabled: OFF
      ├─► dmScope: per-channel-peer (isolates session per conversation)
      │
      ├─► Indexed corpus (READ-ONLY for Caroline):
      │     /opt/hydra/workspaces/support/reference/
      │       • common-issues.md            (doctrine row #7 + Rules 1+2)
      │       • active-incidents.md         (NEW, Aaron-editable)
      │       • credits-and-profiles.md
      │       • faq.md
      │       • platform-features.md
      │       • products-and-pricing.md
      │       • subscriptions-and-billing.md
      │
      ▼
LLM (openai/gpt-5.5 via openrouter) → Caroline's reply
                                            │
                                            ├─► If "I'll flag/escalate/send to team" appears in reply
                                            │   ↳ Rule 1 enforcement requires create_ticket same turn
                                            │
                                            └─► If concrete pushback signal in user message
                                                ↳ Rule 2 enforcement requires create_ticket
```

## Detailed design

### 1. Enable `memorySearch` on the support agent

Edit `openclaw-edge.json`, agent `support` block (currently `memorySearch.enabled: false` at line 93):

```json
"memorySearch": {
  "enabled": true,
  "autoRecall": true,
  "autoCapture": false,
  "remote": {
    "provider": "openai",
    "model": "text-embedding-3-small",
    "apiKey": { "source": "env", "id": "OPENAI_EMBEDDING_API_KEY" }
  },
  "qmd": {
    "paths": ["reference"],
    "scope": "workspace",
    "update": { "onBoot": true, "interval": "5m" }
  },
  "store": {
    "path": "/root/.openclaw-edge/memory/{agentId}.sqlite"
  }
}
```

Concrete decisions:
- `autoRecall: true` — pre-prompt injection on every user message.
- `autoCapture: false` — Caroline does not write to memory. Doctrine is read-only.
- `paths: ["reference"]` — only the `reference/` subdirectory is indexed. SOUL.md, TOOLS.md, sessions/, tickets/, api-logs/ are excluded.
- `update.interval: "5m"` — file changes propagate to the index within 5 minutes. Aaron-edits to `active-incidents.md` go live without a deploy.
- `update.onBoot: true` — full reindex on gateway start so we never run stale.
- `store.path` uses `{agentId}` token — Caroline's qmd store is at `support.sqlite`, isolated from any future memory-using agent.

**Verify before merging:** the `{agentId}` token expansion and the exact key names (`autoRecall`, `qmd.paths`, `qmd.update.interval`) come from openclaw 2026.5.5 runtime symbols and research-agent reports. Before this PR ships, run `openclaw doctor --profile edge` and `openclaw memory status --agent support --profile edge --json` against the proposed config on a non-production profile (`dev` or `test`) and confirm the schema is accepted without warnings. If key names differ, update this section before merging.

### 2. New file: `reference/active-incidents.md`

Aaron-editable file in the existing `reference/` directory. Initial content captures the current analytics platform migration:

```markdown
# Active Incidents

Current platform issues that affect customer-facing answers. When an incident
ends, delete its block. When a new incident starts, append a new block.

---

## Analytics platform migration (active since 2026-04)

**Trigger keywords:** analytics, streams, stream count, data not updating, data
frozen, stuck in [month], numbers not moving.

**Narrative:** "We're in the middle of an analytics platform migration and
server move, so refresh has been lagging across many accounts right now. Your
data is being tracked normally in the background." Do NOT call this a refresh
delay, a sync issue, or a bug. Do NOT quote specific timing.

**Resolution path:** follow common-issues.md row #7. Call profile_status first.
If customer accepts the narrative, close out — no ticket. If customer pushes
back (Rule 2 below), create_ticket with actionType analytics-followup in the
same turn as the escalation language (Rule 1).

**Owner:** Aaron / engineering.
```

This file is indexed by qmd and auto-injected when a customer message mentions any trigger keyword. Aaron edits this file directly (in repo or hot-patched live on the server with PR catch-up per `feedback_hot_patch_pattern.md`) to update the narrative as platform state changes.

### 3. `common-issues.md` row #7 additions

Append two new sub-rules to the existing analytics row (after the existing "Resolution path" block, before "Never promise"):

```markdown
**Rule 1 — Escalation language and the tool call are atomic.**

If your reply contains any of the following phrases (or close variants), you
MUST call `create_ticket` in the same turn — not the next turn, the same turn:

- "I'll flag this"
- "I'll escalate this"
- "I'll send this to the team"
- "I'll get this in front of engineering"
- "I'll route this for review"
- "I've sent this to a person"

If the tool call did not succeed, do not say you escalated. Either retry the
tool call or explicitly tell the customer the system could not file the ticket
right now and ask them to try again in a few minutes. Never imply an
escalation happened when it did not.

**Rule 2 — Concrete pushback always tickets.**

The following customer signals each independently mandate a `create_ticket`
call with actionType `analytics-followup`, regardless of whether you have
asked any follow-up questions yet:

- Customer repeats the analytics complaint after the upgrade-in-progress narrative.
- Customer cites a specific stuck number ("259,759,141", "stuck at 90k").
- Customer cites a duration ("weeks", "months", "since April").
- Customer explicitly asks for a human ("can I speak to a person", "is there a real person").
- Customer expresses clear frustration after a non-resolving reply ("can yall fix this", "this is unacceptable", "I've contacted support multiple times").

These signals override the troubleshooting decision tree. Do not ask for a
screenshot, a "log out and back in", or a billing seat re-check after any of
these signals fire — those are forbidden after Rule 2 triggers.
```

### 4. CI invariant test

Add a test that asserts the support agent's safe state in `openclaw-edge.json`. Must fail the deploy if a future PR flips any of:

- `agents.list[support].memorySearch.autoCapture` → not `false`
- `agents.list[support].memorySearch.qmd.paths` → includes anything outside `reference/`
- `plugins.entries["memory-core"].config.dreaming.enabled` → `true`
- `profiles.edge.session.dmScope` → not `"per-channel-peer"`

Test framework + file location should match existing CI tests in this repo (e.g. the same place `pr-validate` runs config-shape assertions). Pseudocode form — concrete syntax follows existing repo conventions:

```text
read openclaw-edge.json
support = agents.list[support]
assert support.memorySearch.autoCapture === false
assert support.memorySearch.qmd.paths === ["reference"]
assert (plugins.entries["memory-core"].config.dreaming.enabled ?? false) === false
assert profiles.edge.session.dmScope === "per-channel-peer"
```

### 5. Initial index + verification

After config change deploys:

```bash
openclaw memory index --force --agent support --profile edge
openclaw memory status --agent support --profile edge --deep
openclaw memory search "analytics streams stuck" --agent support --profile edge --max-results 5
```

The search should return chunks from `common-issues.md` row #7 and `active-incidents.md`. If it doesn't, the embedding provider auth or the index path is wrong — fail loud, do not proceed.

### 6. Verify `memory_search` / `memory_get` tool surface

Per upstream issue [#76603](https://github.com/openclaw/openclaw/issues/76603), there is a regression in openclaw 2026.5.2 where the memory tools can silently drop off the agent's tool surface. We are on 2026.5.5 — should verify the tools are listed:

```bash
openclaw agent tools list --agent support --profile edge | grep -E "memory_search|memory_get"
```

Both should appear. If they don't, hold the rollout and file an issue against our runtime version pinning.

### 7. Companion: empty ClickUp custom fields (separate PR, noted here)

Tickets currently land in ClickUp with empty custom fields (Profile ID, Muso URL, Intercom Link, Customer Email all blank). Caroline puts everything in the description. Ops can't filter or join by Profile ID. This is a known follow-up captured in memory `project_support_tools_deploy.md` and is **out of scope for this PR** — separate change to `support-tools/dist/tools/create-ticket.js` that maps the structured `details` payload into the custom_fields array.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Embedding provider outage (OpenAI API down) | Low | autoRecall fails open → Caroline falls back to pre-RAG behavior (current state). Add monitor on `openclaw memory status` to Slack if provider goes unhealthy. |
| Index goes stale on Aaron's hot-patch to `active-incidents.md` | Medium | `update.interval: "5m"` caps staleness at 5 min. For urgent updates, manual `openclaw memory index --force`. |
| Per-turn embedding API cost overrun | Low | text-embedding-3-small is $0.02/M tokens. At ~50 customer messages/day × ~50 tokens each = ~75k tokens/month = ~$0.002/month. Negligible. Set a billing alert at $20/mo as belt-and-suspenders. |
| Caroline somehow writes to `reference/` and pollutes her own RAG | Very low (no write tool in support-tools allowlist) | Filesystem permissions: `reference/` owned by root, support agent runs with read-only mount. Verify before rollout. |
| Future PR flips `autoCapture` or `dreaming` on | Medium | CI invariant test (section 4) blocks merge. Memory file `project_caroline_rag_invariants.md` documents the reasoning. |
| Tool-surface regression #76603 hits us | Low (we're on 2026.5.5) | Pre-flight verification (section 6) catches it before rollout. |
| Doctrine retrieved but Caroline ignores it (e.g. LLM regression) | Low–Medium | Same risk exists today with on-demand reads. Layer 1 (Rules 1+2) makes the failure mode louder; sanitizer hook can enforce "if reply contains escalation language → create_ticket in same turn" mechanically. |
| Customer-message embedding leaks PII to OpenAI | Already accepted | Caroline already sends customer messages to openrouter→openai for LLM completion. Embeddings are the same trust boundary. No new exposure. |

## Why no Dreaming (one-page summary)

Researched independently across four parallel agents 2026-05-14. Convergent answer: do not enable dreaming on Caroline. Reasons:

1. **#63921** — REM phase has shipped unredacted PII into MEMORY.md in production. Caroline sees emails, profile UUIDs, payment status — exact wrong agent for an unfixed PII leak.
2. **#65374** — dreaming sweep pools session corpus across agents without agent-id tagging. Caroline could absorb ops or credit-verification context. We have memory of this exact failure pattern from PR #213 and #245 in different contexts.
3. **#65550** — documented runaway dreaming loop, real cost overruns ($4.35 wasted on zero-confidence garbage).
4. **#66947** — dreaming pollutes daily memory files.
5. **GDPR Article 17** — right-to-deletion on dreamed memories is manual (grep + delete files before next Deep sweep). No retroactive tombstoning. We are the controller; openclaw is the processor.
6. **No customer-facing postmortems exist.** All reported Dreaming outcomes are single-operator dev/personal-assistant use cases. We'd be the early data point. Not the right place to take that risk given the customer-trust cost of a leak.

If we revisit later — wait for #65374 and #63921 to close upstream, run a 30-day pilot in `review` mode, and audit DREAMS.md weekly. Not now.

## Rollout

Two PRs, sequenced:

**PR A (Layer 1 — analytics gap, low-risk):**
- Edit `reference/common-issues.md` row #7 to append Rules 1 and 2.
- Optionally add a sanitizer hook in the existing `output-sanitizer` skill that detects escalation language without a same-turn `create_ticket` call and either auto-injects the call or refuses the reply.
- Ships standalone. Stops the bleeding within 1 day.

**PR B (Layer 2 — RAG enablement, structural):**
- Flip `memorySearch.enabled: true` in `openclaw-edge.json` with the config block in section 1.
- Add `reference/active-incidents.md`.
- Add CI invariant test (section 4).
- Add `OPENAI_EMBEDDING_API_KEY` to `/etc/openclaw/edge.env` and `shared.env` if not already present (reuse `OPENAI_API_KEY` if already provisioned for openrouter — verify before adding a new env var).
- Run initial index + verify retrieval before flipping to live traffic.

PR B can wait if PR A delivers enough. Decision point after PR A ships and runs for ~48h: if analytics-ticket rate is at or above 90%, PR B is doctrine-discovery scaffolding for future incidents (still valuable, less urgent). If still below 90%, PR B is the next required move.

## Out-of-scope follow-ups (captured for memory)

- ClickUp custom-field population (`project_support_tools_deploy.md`)
- Audit of other reference docs for similar intent-action gaps (refund-retention, profile-merge intake)
- Open Linear ticket for memory-core upstream issue tracking; subscribe to #65374, #63921, #76603

## Open questions

1. Does `OPENAI_API_KEY` (already used for openrouter completions) double as the embedding key, or does openrouter proxy embeddings too? Need to confirm before section 1 config exact form.
2. Embedding store path `/root/.openclaw-edge/memory/{agentId}.sqlite` — does this need backup? It's regeneratable from the indexed files, so probably no. Confirm by checking deploy.sh backup scope.
3. Should the CI invariant test live in this repo (`hydra/tests/`) or in the broader monorepo test surface?

## Final policy (v2) — source of truth, supersedes everything above

This section reflects the **shipped state** after the 2026-05-14 policy flip. Where any earlier section conflicts, this one wins.

**Layer 1 — analytics doctrine in `common-issues.md` row #7:**

- Caroline does NOT call `create_ticket` for analytics/streams concerns. No `actionType: analytics-followup`, no `support-general`, no other action type for this row. Analytics is platform-wide; there is no per-account fix and no per-account team follow-up happening.
- Caroline does NOT say "I'll flag your profile" / "I'll escalate" / "I've sent this to a person" / "you'll hear back within N business days" / any phrase implying per-account human follow-up.
- On first analytics complaint: call `profile_status`, deliver the migration narrative ("we're in the middle of an analytics platform migration and server move; your data is being tracked normally in the background"), close out if the customer accepts.
- On pushback (repeated complaint, specific stuck number, duration like "since April", asking for a human, frustration): acknowledge honestly that there is no per-account timeline. Offer the one real lifeline — *"if you message back in a couple of weeks, I can re-check what your profile is showing then"*. No tickets. No SLA promises. No escalation theatre.
- **Rule 1 (say-it=do-it) remains in force for non-analytics categories.** Credit changes, refunds, profile merges, claim disputes, login issues — anywhere `create_ticket` is a legitimate action — Caroline must NOT produce escalation language without firing the tool in the same turn. Analytics is the carved-out exception because the tool call itself is forbidden for that row.
- **Rule 2 (concrete pushback → analytics ticket) is removed entirely.** Replaced by the honest-no-ticket fallback above.

**Layer 2 — RAG infrastructure (unchanged from v1):**

- `agents.list[support].memorySearch.enabled: true` with OpenRouter-proxied OpenAI `text-embedding-3-small` indexing read-only `workspaces/support/reference/`. Caroline gets `memory_search` / `memory_get` tools.
- `reference/active-incidents.md` is the Aaron-editable narrative file. Initial entry encodes the analytics migration with the same no-ticket / no-SLA-promise doctrine as common-issues.md row #7.
- autoCapture / Dreaming / active-memory plugin all disabled. Five CI invariants in `validate-shared-config.sh` block any PR that flips them.
- Post-deploy smoke test (`validate-caroline-rag.sh`) wired into `deploy.sh` non-fatally; Slack alerts on failure.

**Why the policy flipped:**

The v1 design measured "ticket-create rate" as the success metric and aimed for 75–100% on analytics pushback. The data showed Caroline was already at 54% post-PR-270 and Rules 1+2 would push that higher. But the upstream question — *"is anyone actioning these tickets?"* — was never answered in v1. On review, the answer was no: the 42 open `analytics-followup` tasks in ClickUp had no per-account work happening, the 2-business-day SLA wasn't real, and customers like Tyler Krupsky were returning angry because the ticket promise hadn't been kept. The v1 fix would have multiplied the volume of unkept promises. The v2 fix removes the promise.

**Net effect:**

- Customer-facing: Caroline stops promising follow-up that isn't happening. The migration narrative is the entire response; honesty replaces theatre.
- Ops-facing: Jan's queue stops getting analytics-followup noise. The 42 currently-open ClickUp tasks can be closed.
- Trust: tightens the gap between "what Caroline says" and "what actually happens after the conversation ends" — the core thing Aaron flagged.

## Revision history

- **2026-05-14 — v1 draft:** initial design after brainstorm session reviewing post-PR-270 data (48 sessions, 25% missed-escalation tail). Decision converged on RAG (memorySearch + autoRecall) + read-only indexed reference + Rules 1+2 in common-issues.md row #7. Dreaming explicitly disabled based on four parallel research agents converging on upstream production bugs.

- **2026-05-14 — v2 policy reversed:** Nick + Aaron determined the v1 ticket-creation-on-pushback approach was multiplying the volume of unkept SLA promises. Rule 2 removed entirely; Rule 1 scoped to non-analytics rows only; step 3 of `common-issues.md` row #7 rewritten with honest-no-ticket fallback. `active-incidents.md` rewritten to match. Layer 2 RAG infrastructure unchanged. See "Final policy (v2)" above for shipped state.
