# Intercom Channel Plugin — Design Spec

**Date**: 2026-03-23
**Author**: Nick Sollazzo (CTO)
**ADR**: [ADR-024](https://github.com/Muso-AI/muso-docs/blob/main/adr/024-openclaw-intercom-channel-for-support-supervision.md)
**Timeline**: 2 days (T1 + T2 + reply handler + handoff)
**Status**: Draft

---

## 1. Overview

Build an OpenClaw channel plugin (`@muso/openclaw-intercom`) that connects Intercom as an inbound/outbound messaging channel for the `support` agent. Customers message in Intercom, the AI agent responds, and human ops can take over mid-conversation natively in Intercom without losing context.

This implements ADR-024 Decisions 1-6 and 9, scoped to what can be built and tested without Intercom API credentials.

## 2. Plugin Structure

```
hydra/
└── plugins/
    └── openclaw-intercom/
        ├── package.json
        ├── openclaw.plugin.json
        ├── tsconfig.json
        ├── vitest.config.ts
        ├── src/
        │   ├── index.ts              # plugin entry point
        │   ├── channel.ts            # createChatChannelPlugin
        │   ├── webhook.ts            # registerHttpRoute + HMAC + event parsing
        │   ├── session-key.ts        # deterministic key builder
        │   ├── handoff.ts            # agent_active/human_takeover state machine
        │   ├── outbound.ts           # IntercomClient interface + implementations
        │   ├── escalation.ts         # deterministic keyword-based escalation rules
        │   ├── config.ts             # typed config schema
        │   ├── types.ts              # Intercom webhook payload types
        │   └── filters.ts            # event filtering + idempotency
        └── tests/
            ├── webhook.test.ts
            ├── session-key.test.ts
            ├── handoff.test.ts
            ├── outbound.test.ts
            ├── escalation.test.ts
            └── fixtures/
                ├── conversation-user-created.json
                ├── conversation-user-replied.json
                ├── conversation-admin-replied.json
                ├── conversation-assigned.json
                └── conversation-closed.json
```

## 3. Configuration

New `channels.intercom` section in `openclaw.json`:

```json
{
  "channels": {
    "intercom": {
      "accounts": {
        "default": {
          "enabled": false,
          "workspaceId": "<intercom_workspace_id>",
          "token": "VAULT",
          "webhookSecret": "VAULT",
          "botAdminId": "<bot_admin_id>",
          "defaultInboxId": "<inbox_id>",
          "fallbackSlackSupervisionChannel": "<slack_channel_id>",
          "fallbackAcknowledgement": "We're looking into this and will get back to you shortly.",
          "requireMappedHumanAdmin": true,
          "adminMapping": {
            "<slack_user_id>": "<intercom_admin_id>"
          }
        }
      }
    }
  }
}
```

- `enabled`: Kill switch. `false` stops autonomous handling and outbound replies.
- `workspaceId`: Scopes session keys to avoid prod/staging collisions.
- `token`: Intercom API Bearer token (injected from Vault at deploy time).
- `webhookSecret`: HMAC-SHA256 signing secret for webhook validation.
- `botAdminId`: Intercom admin ID used for agent-authored replies (e.g. "Clio").
- `defaultInboxId`: Inbox where OpenClaw-managed conversations live.
- `fallbackSlackSupervisionChannel`: Slack channel ID for escalation cards (expired-context reopens, blocked takeovers).
- `requireMappedHumanAdmin`: When `true`, takeover is blocked with an explicit error if the Slack operator has no Intercom admin mapping. No unmapped default identity is used.
- `fallbackAcknowledgement`: Configurable customer-facing message sent when the LLM fails to produce a reply. Ops can update the wording without a code deploy.
- `adminMapping`: Slack-to-Intercom admin ID map for human takeover identity resolution. **v1 simplification**: this is static config in `openclaw.json`. ADR-024 Decision 5 recommends runtime-configurable mapping owned by Support Operations. The runtime-managed directory is deferred until the support team exceeds 3 people (see Section 9).

**Note**: Config is wrapped in `accounts.default` to follow OpenClaw's multi-account convention (matching Slack's `channels.slack.accounts` pattern in the existing `openclaw.json`). v1 uses a single account; the structure supports future multi-workspace setups without migration.

## 4. Channel Registration

Entry point uses `defineChannelPluginEntry` (imported from `openclaw/plugin-sdk/core`):

```typescript
// src/index.ts
import { defineChannelPluginEntry } from "openclaw/plugin-sdk/core";
import { intercomPlugin } from "./channel.js";

export default defineChannelPluginEntry({
  id: "intercom",
  name: "Intercom",
  description: "Intercom customer support channel",
  plugin: intercomPlugin,
});
```

The `intercomPlugin` is built via `createChatChannelPlugin` (from `openclaw/plugin-sdk/core`), following the same pattern as the Google Chat plugin. Webhook registration happens inside `gateway.startAccount` on the `base` object — this ties the webhook route to the account lifecycle so `enabled: false` properly tears down the endpoint:

```typescript
// src/channel.ts (simplified)
import { createChatChannelPlugin } from "openclaw/plugin-sdk/core";

export const intercomPlugin = createChatChannelPlugin({
  base: {
    id: "intercom",
    capabilities: { chatTypes: ["direct"] },
    config: { /* resolveAccount, inspectAccount, listAccountIds */ },
    gateway: {
      startAccount: async (ctx) => {
        // Register webhook route inside account lifecycle
        // so enabled: false tears it down
        await runPassiveAccountLifecycle({
          abortSignal: ctx.abortSignal,
          start: async () =>
            await startIntercomWebhookMonitor({
              account: ctx.account,
              config: ctx.cfg,
              runtime: ctx.runtime,
              abortSignal: ctx.abortSignal,
            }),
          stop: async (unregister) => { unregister?.(); },
        });
      },
    },
  },
  security: { dm: { /* open — Intercom is public-facing */ } },
  threading: { topLevelReplyToMode: "reply" },
  outbound: {
    attachedResults: {
      channel: "intercom",
      sendText: async ({ cfg, to, text, accountId }) => {
        // Calls Intercom Conversations Reply API
        // Pre-send validation (handoff state check) happens here
      },
    },
  },
});
```

Key architectural points:
- `gateway.startAccount` registers the webhook HTTP route and keeps the account "running" via `runPassiveAccountLifecycle` (parks a promise on `ctx.abortSignal`). This matches the Google Chat plugin pattern and avoids the infinite-restart bug that affects webhook channels that resolve `startAccount` immediately.
- `resolveAccount()`: reads `channels.intercom.accounts.default` from config, extracts token + workspace ID
- `inspectAccount()`: reports enabled/configured status without exposing secrets
- `outbound.attachedResults.sendText()`: calls Intercom Conversations Reply API with pre-send handoff validation
- `security.dm`: open by default (Intercom is a public customer-facing channel, not DM-gated)
- `capabilities.chatTypes: ["direct"]`: Intercom conversations are 1:1 customer-to-support threads

## 5. Session Model

### Session Key Format

```
agent:support:intercom:<workspace_id>:conversation:<conversation_id>
```

The agent ID is `support` (matching `workspaces/support/` and `agents.list[].id: "support"` in `openclaw.json`). The ADR references `agent:ops:intercom:...` — this spec uses `support` because that is the actual agent ID in the HYDRA deployment. The ADR's `ops` was a placeholder for the agent that handles customer support; in HYDRA, that role is filled by the `support` agent.

Key properties:
- One session per Intercom conversation. Never per-participant or per-assignee.
- Workspace-scoped to avoid collisions across environments.
- Deterministic: same conversation ID always resolves to the same key.
- Reopens reuse the same key. A closed conversation that reopens resumes the existing session.

### Session State

Persisted alongside OpenClaw's native session storage:

```typescript
type IntercomSessionState = {
  conversationId: string;
  workspaceId: string;
  handoffMode: "agent_active" | "human_takeover";
  lifecycleState: "open" | "snoozed" | "closed";
  currentAssigneeId: string | null;
  lastEventId: string | null;
  processedEventIds: string[];  // bounded FIFO array, ~1000 entries, serializable as JSON
  outboundMessageIds: string[]; // bounded FIFO array, ~500 entries, IDs of messages we sent for self-reply filtering
  createdAt: string;
  updatedAt: string;
};
```

At runtime, `processedEventIds` is loaded into a `Set<string>` for O(1) lookup. On persistence, it is serialized as a JSON array with FIFO eviction when the array exceeds 1000 entries.

### Idempotency

Store the last ~1000 event IDs in `processedEventIds`. Reject duplicate webhook deliveries before they touch the session transcript. Bounded FIFO prevents unbounded growth.

### Lifecycle Transitions

- `closed` → suppress agent replies, session stays queryable. Each `closed` event resets the retention clock.
- `snoozed` → suppress agent replies.
- `reopened` → resume same session key, restore handling mode based on current assignee.
- **Expired-context reopen**: if a conversation reopens but session data is missing, compacted beyond recovery, or was deleted by a redaction workflow, the system reuses the same session key but automatically sets `human_takeover` and posts an escalation card to `fallbackSlackSupervisionChannel` with the conversation ID, contact reference, and reason. The agent does not resume autonomous replies until a human confirms context is sufficient.

## 6. Webhook Ingestion

### Handler Flow

The webhook HTTP route is registered inside `gateway.startAccount` (see Section 4), tying it to the account lifecycle. When `enabled: false`, the route is torn down and incoming webhooks receive no handler.

```
POST /intercom/webhook
  → validate HMAC-SHA256 signature (reject 401 if invalid)
  → parse payload, extract topic + event ID
  → check idempotency (reject if event ID already processed)
  → classify event type
  → run escalation check on customer messages (see Section 8.1)
  → route to handler
  → respond 200 immediately
```

### Event Classification

| Intercom Topic | Action | Route to Agent? |
|---|---|---|
| `conversation.user.created` | New conversation → create session, dispatch | Yes |
| `conversation.user.replied` | Customer follow-up → append, dispatch. **If `lifecycleState` is `closed`, treat as implicit reopen**: transition to `open`, restore handling mode based on current assignee, then dispatch. | Yes |
| `conversation.admin.replied` | Bot or human reply → record, filter out | No |
| `conversation.admin.assigned` | Assignment change → update handoff state | No |
| `conversation.admin.closed` | Mark lifecycle closed, suppress agent | No |
| `conversation.admin.snoozed` | Mark lifecycle snoozed, suppress agent | No |
| `conversation.admin.opened` | Resume session, restore handling mode | Conditional |
| `conversation.admin.noted` | Internal note → ignore entirely | No |

### Self-Reply Filtering

When the agent sends an outbound reply, store the returned Intercom message ID in `outboundMessageIds`. When webhooks echo that reply back as `conversation.admin.replied`, match against stored IDs and discard. Prevents loops independent of handoff state.

### HMAC Validation

Intercom signs webhooks with HMAC-SHA256 using the webhook secret. Validate the `X-Hub-Signature` header against the raw request body before any processing. Code works now; real secret injected at deploy time.

## 7. Outbound Reply Adapter

### Interface

```typescript
interface IntercomClient {
  replyToConversation(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string }>;

  assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
  }): Promise<void>;

  getConversation(params: {
    conversationId: string;
  }): Promise<IntercomConversation>;
}
```

### Implementations

- **`RealIntercomClient`**: Calls `POST /conversations/{id}/reply` with Bearer token auth. Production use.
- **`MockIntercomClient`**: Returns predictable responses, records calls. Used in tests.

### Outbound Flow

```
Agent generates reply
  → pre-send validation (reload session state, verify agent_active + open)
  → run escalation check on agent response (see Section 8.1)
  → format payload (message_type: "comment", type: "admin", admin_id: botAdminId)
  → POST to Intercom Conversations API
  → store returned message ID (for self-reply filtering)
  → update session updatedAt
```

### Pre-Send Validation (Race Condition Guard)

Before every outbound send, reload current session state and verify:
1. `handoffMode` is still `agent_active`
2. `lifecycleState` is still `open`
3. No human takeover happened during agent generation

If any check fails: abort send silently, log the near-miss.

### LLM Failure / Degradation Behavior

If the agent fails to produce a reply (LLM provider error, rate limit, timeout, or latency exceeds bounds):
1. Send the configurable `fallbackAcknowledgement` message to the customer (from `channels.intercom.accounts.default.fallbackAcknowledgement`).
2. Log the failure with context (error type, conversation ID, latency).
3. If failures persist (3+ consecutive for the same session), auto-escalate to `human_takeover`.

The fallback acknowledgement should be accepted by Intercom within 3 seconds p95.

### Rate Limiting

Intercom returns `429` with `Retry-After`. Retry with capped exponential backoff + jitter (max 3 retries, max 30s total wait). v1 retry is in-memory.

### Latency Targets

Per ADR Decision 7 (measured, logged, not alerted in v1):
- **Median** end-to-end reply latency (webhook accepted → Intercom reply accepted): < 3 seconds
- **p95** end-to-end reply latency: < 8 seconds
- **p95** channel-layer dispatch (outbound adapter → Intercom API acceptance): < 2 seconds
- If targets exceeded, prefer fallback acknowledgement over silent delay

## 8. Handoff State Machine

### Modes

```
                 ┌──────────────┐
    new convo ──>│ agent_active  │<── hand back (Slack cmd or assignment)
                 └──────┬───────┘
                        │
          human takes over (assignment or admin reply)
                        │
                        v
                 ┌──────────────────┐
                 │ human_takeover   │
                 └──────┬───────────┘
                        │
              close / snooze / hand back
                   │         │
                   v         v
              (closed)   (agent_active)
```

**v1 simplification**: ADR-024 Decision 4 defines three modes: `agent_active`, `human_takeover`, and `handoff_back_to_agent`. In v1, `handoff_back_to_agent` is collapsed into a direct transition back to `agent_active`. The transient state provides no audit distinction yet between "never handed off" and "handed back." If audit requirements emerge, the intermediate state can be added without changing the external behavior.

### Transition Triggers

| Trigger | Source | State Change |
|---|---|---|
| Admin assigned via Intercom (non-bot) | Webhook `conversation.admin.assigned` | → `human_takeover` |
| Admin replies in Intercom (non-bot) | Webhook `conversation.admin.replied` | → `human_takeover` (implicit) |
| Slack command: take over | Operations agent (future) | → `human_takeover` + reassign |
| Slack command: hand back | Operations agent (future) | → `agent_active` + reassign to bot |
| Conversation closed | Webhook | lifecycle → `closed`, agent suppressed |
| Conversation snoozed | Webhook | lifecycle → `snoozed`, agent suppressed |
| Conversation reopened | Webhook | lifecycle → `open`, mode per assignee |
| Unmapped Slack operator attempts takeover | Slack (future) | Blocked with explicit error, audit event logged |
| Escalation rule triggered | Inbound message filter | → `human_takeover`, notify fallback channel |

### Key Rules

- Agent reply suppression is enforced in code, not via prompt instructions.
- An admin replying directly in Intercom implicitly triggers takeover — if a non-bot admin reply is detected, flip to `human_takeover`.
- On reopen: if assigned to bot admin → `agent_active`; if assigned to human → `human_takeover`.
- All transitions are persisted and logged.
- v1 is binary: agent active or human active. No co-pilot/draft mode.
- No auto-handback timer. Human must explicitly hand back.

### Human Takeover Experience

When a human takes over, they work **natively in Intercom** — full inbox experience with macros, CRM sidebar, canned responses, internal notes, tags, snooze, SLA timers. OpenClaw watches via webhooks and stays quiet. The customer sees a seamless handoff from AI to human in the same conversation thread.

### 8.1 Deterministic Escalation Rules

Per ADR Decision 7, v1 escalation is deterministic and rule-based — not dependent on implicit model judgment alone. SOUL.md prompt constraints are the secondary backstop, not the primary mechanism.

`escalation.ts` implements keyword/pattern matching on inbound customer messages. When a match triggers, the system auto-escalates to `human_takeover` and sends the customer a safe acknowledgement.

**Escalation triggers** (case-insensitive, word-boundary matching via `\b` regex, checked before agent dispatch):

| Category | Patterns |
|---|---|
| Billing disputes | `\brefund\b`, `\bchargeback\b`, `\bdispute\b`, `\binvoice dispute\b`, `\bpayment failed\b`, `\bunauthorized charge\b` |
| Legal | `\blawyer\b`, `\battorney\b`, `\blawsuit\b`, `\bsue\b`, `\bcourt\b`, `\bsubpoena\b`, `\blegal action\b`, `\blegal threat\b` |
| Account security | `\bhacked\b`, `\bcompromised\b`, `\bunauthorized access\b`, `\bstolen account\b`, `\bpassword breach\b` |
| Abuse reports | `\bharassment\b`, `\babuse report\b`, `\bthreatening\b`, `\bphishing\b` |

**Word-boundary guards**: Patterns use `\b` (word boundary) to prevent false positives like "charged up" matching billing, or "is this legal" matching legal threats. Multi-word patterns (e.g. "legal action", "unauthorized charge") require the full phrase match. Tests must include false-positive scenarios with real Muso customer messages (profile updates, licensing questions, feature inquiries).

When triggered:
1. Set `handoffMode` to `human_takeover`
2. Send customer: "I'm connecting you with our support team for this. Someone will be with you shortly."
3. Post escalation card to `fallbackSlackSupervisionChannel` with conversation ID, matched pattern, and message snippet
4. Log the escalation for audit

These rules are additive — SOUL.md constraints still apply as a secondary layer.

## 9. Deferred Items

| Item | ADR Task | Reason | Build When |
|---|---|---|---|
| Slack supervision commands (list, inspect, inject, take over) | T4 | Humans use Intercom natively for now | After first prod traffic validates core loop |
| Periodic reconciliation job | T8 | Webhooks-only state sync in v1 | After 2 weeks prod traffic reveals drift patterns |
| Durable retry queue | T3 | In-memory retry for v1. Survives transient failures, not restarts. | Before first prod customer traffic |
| Kill switch runbook | T8 | `channels.intercom.enabled = false` works. Ops doc needed. | Before prod rollout |
| Contact-level index | Decision 2 | Lookup convenience, not required for core flow | When ops requests multi-conversation contact lookup |
| Runtime admin identity mapping | Decision 5 | Static config in v1 (see Section 3). ADR recommends runtime-managed, auditable directory owned by Support Ops. | When support team exceeds 3 people |
| Transcript retention / compaction | Decision 2, 7 | OpenClaw native compaction for v1. 180-day policy is operational. | Before compliance review |
| Observability dashboards / alerting | Decision 7 | Structured logging + latency measurement for v1. Prometheus metrics and Grafana dashboards come later. | Alongside prod deployment to Node 8 |
| Startup reconciliation | T8 | Agent stays quiet until next customer message | Before broad rollout |
| Automation exclusion preflight | Decision 6 | v1 assumes Fin is disabled for managed conversations | Before prod rollout as config validation |

## 10. Testing Strategy

All tests run against mocked Intercom payloads. No API key needed.

### Unit Tests

- **`session-key.test.ts`**: Deterministic key generation, workspace scoping, collision avoidance
- **`webhook.test.ts`**: HMAC validation (valid/invalid/missing), event classification, idempotency (duplicate rejection), self-reply filtering
- **`handoff.test.ts`**: All state transitions, implicit takeover on admin reply, reopen behavior (including expired-context fail-safe), pre-send validation race condition guard
- **`outbound.test.ts`**: Reply formatting, retry on 429, abort on handoff change, LLM failure fallback
- **`escalation.test.ts`**: Pattern matching for all escalation categories, case insensitivity, false positive resistance

### Test Fixtures

Real-shaped Intercom webhook payloads in `tests/fixtures/` covering all event types. Derived from Intercom's public webhook documentation.

### Integration Test (Future)

End-to-end flow against staging Intercom workspace. Requires API key (Aaron).

## 11. Security Impact

### Egress

The Intercom API calls happen inside the channel plugin, which runs in the **Gateway process** — not inside the `support` agent's NemoClaw sandbox. The Gateway already has network access for Slack Socket Mode, GitHub, and other integrations. No change to the `support` agent's NemoClaw egress allowlist is needed.

However, the Gateway's own egress policy (`policies/egress-allowlist.yaml`) needs `api.intercom.io:443` added as a permitted outbound destination.

### Agent Isolation

The `support` agent's tool deny list does NOT change. The agent itself remains isolated with its 4 tools (`profile_lookup`, `credits_search`, `subscription_status`, `create_ticket`). The channel plugin handles all Intercom communication at the Gateway layer — the agent just sees inbound messages and produces responses, same as with Slack.

### Webhook Ingress

Node 8's iptables need to allow inbound HTTPS on the Gateway port from Intercom's webhook source IPs (or from Cloudflare if proxied). This is an ops task for Artem D at deploy time.

## 12. Day-by-Day Plan

### Day 1: Session model + webhook ingestion (T1 + T2)
- Scaffold plugin package (package.json, manifest, tsconfig, vitest)
- Implement `session-key.ts` + tests
- Implement `types.ts` (Intercom webhook payload types)
- Implement `config.ts` (typed config schema)
- Implement `filters.ts` (event classification, idempotency)
- Implement `escalation.ts` (keyword-based escalation rules) + tests
- Implement `webhook.ts` (HMAC validation, event routing)
- Implement `channel.ts` (createChatChannelPlugin with resolveAccount, inspectAccount)
- Implement `index.ts` (plugin entry point, see Section 4 for pattern)
- Write webhook tests with fixtures

### Day 2: Outbound reply + handoff (T3 partial + T6 partial)
- Implement `outbound.ts` (IntercomClient interface + Real + Mock implementations)
- Wire outbound into channel plugin's sendText adapter
- Add LLM failure fallback behavior
- Implement `handoff.ts` (state machine, transitions, pre-send validation)
- Wire handoff state into webhook handler (assignment changes, admin replies, lifecycle events)
- Write handoff tests (all transitions, race condition guard, expired-context reopen)
- Write outbound tests (reply formatting, retry, abort, fallback)
- PR to hydra repo
