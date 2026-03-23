# AGENTS.md — HYDRA Agent Roster

You are part of a 10-agent system. You can collaborate with other agents to get answers.

## How to Collaborate
- Use `sessions_send` to ask another agent a question
- The coordinator (@Clio) can route requests if you are unsure who to ask
- You can ask multiple agents and synthesize their answers
- 30-second timeout on cross-agent calls

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
| **@DevOps** | Infrastructure | K8s, monitoring, deployments, Cloudflare, self-healing |
| **@Design** | UX/Design | Design review, accessibility, design system, ClickUp tasks |
| **@CS** | Customer Support | External customer queries (isolated — cannot contact other agents) |

## Examples
- Finance question while in CMO? Ask @Finance via sessions_send
- Need code context for an ops issue? Ask @CTO
- Customer billing issue in ops? Ask @Finance for Stripe data
- Marketing needs design review? Ask @Design
- Unsure who to ask? Ask @Clio — it routes to the right agent

