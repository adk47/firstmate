# AGENTS.md — HYDRA Agent Roster

You are part of an 11-agent system. You can collaborate with other agents to get answers.

## How to Collaborate

Peer messaging is a two-step RPC flow on the gateway:

1. **Resolve** the peer's session key from its `@Role` label:
   `sessions.resolve({ label: "@CTO" })` → `{ ok: true, key: "agent:cto:main" }`
2. **Send** the question on that session key:
   `sessions.send({ key: "agent:cto:main", message: "..." })`

Notes:
- Use the exact `@Role` handle from the roster below (case-sensitive). Bare names (`cto`, `CTO`, `clio`) will NOT resolve — resolution is by label, not id.
- The coordinator (@Clio) can route if you are unsure who to ask.
- You can ask multiple agents and synthesize their answers.
- **Timeout budget:** pass `timeoutMs: 90000` on `sessions.send`. A cold peer
  (one that hasn't run in ~10+ min) can take 40–80s on its first turn while
  the system prompt and skills recompile from a cold cache; steady-state
  replies typically land in 5–15s. Reserve 30s only if both peers are known
  to be warm.
- If a reply hasn't arrived by the timeout, the send is NOT lost — subscribe
  with `sessions.messages.subscribe({ key })` and poll for the next assistant
  message instead of retrying the send (retrying double-enqueues the work).

## Agent Roster

| Agent | Expertise | Ask them about |
|-------|-----------|---------------|
| **@Clio** | Orchestrator | Routing, cross-department questions, general Muso context |
| **@CEO** | Everything | Strategy, board prep, cross-department synthesis, any escalation |
| **@CMO** | Marketing | Campaigns, B2B outreach, Klaviyo, GHL, ads, Amplitude, Rewardful |
| **@CTO** | Engineering | Architecture, code, data model, Athena queries, n8n, Cloudflare |
| **@QA** | Quality | Testing, bug triage, profile verification, credit investigation |
| **@Finance** | Financial | Stripe, invoices, payouts, ChartMogul, Deel, Anrok, disputes |
| **@Ops** | Operations | Customer support, claiming, credits, fraud, Intercom, refunds |
| **@Ops-Dev** | Operations (Dev) | Dry-run ops testing, credit verification batch |
| **@DevOps** | Infrastructure | K8s, monitoring, deployments, Cloudflare, self-healing |
| **@Design** | UX/Design | Design review, accessibility, design system, ClickUp tasks |
| **@CS** | Customer Support | External customer queries (isolated — cannot contact other agents) |

## Examples
- Finance question while in CMO? Resolve `@Finance` → send on that key
- Need code context for an ops issue? Ask `@CTO`
- Customer billing issue in ops? Ask `@Finance` for Stripe data
- Marketing needs design review? Ask `@Design`
- Unsure who to ask? Ask `@Clio` — it routes to the right agent

## Troubleshooting

`sessions.resolve` returns `No session found with label: @X` means one of:
- The handle is wrong (check the roster — `@Ops` not `@ops`; `@Ops-Dev` not `@OpsDev`).
- The peer's `:main` session has not been provisioned yet. Peer labels are
  populated on every gateway restart and every 5 min by
  `hydra-peer-labels.timer`. If it genuinely missed a new agent, page DevOps.
