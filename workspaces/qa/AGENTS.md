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
- **Timeout budget:** pass `timeoutMs: 300000` on `sessions.send`. A cold peer
  (one that hasn't run in ~10+ min) can take 40–80s on first turn while the
  system prompt and skills recompile from a cold cache, and longer when
  running multi-step shell work (e.g. a sheet create + share + multi-row
  append on @CMO); steady-state replies typically land in 5–15s. Reserve
  60–90s only if the peer is known to be warm and the work is single-shot.
- If a reply hasn't arrived by the timeout, the send is NOT lost — subscribe
  with `sessions.messages.subscribe({ key })` and poll for the next assistant
  message instead of retrying the send (retrying double-enqueues the work).

## Agent Roster

| Agent | Expertise | Ask them about |
|-------|-----------|---------------|
| **@Clio** | Orchestrator | Routing, cross-department questions, general Muso context |
| **@CEO** | Everything | Strategy, board prep, cross-department synthesis, any escalation |
| **@CMO** | Marketing + Google Workspace | Campaigns, B2B outreach, Klaviyo, GHL, ads, Amplitude, Rewardful; **all agents route to @CMO for Google Sheets / Drive / Docs / Gmail / Calendar via `gog`** — default account `a@muso.ai`, share new files with the requester at writer ("Editor") role |
| **@CTO** | Engineering | Architecture, code, data model, Trino queries, n8n, Cloudflare |
| **@QA** | Quality | Testing, bug triage, profile verification, credit investigation |
| **@Finance** | Financial | Stripe, subscriptions, MRR/ARR/churn/LTV, invoices, payouts, Deel, Anrok, disputes |
| **@Ops** | Operations | Customer support, claiming, credits, fraud, Intercom, refunds |
| **@DevOps** | Infrastructure | K8s, monitoring, deployments, Cloudflare, self-healing |
| **@Scout** | Research/Intelligence | Web research (cited reports), competitive & market intelligence, B2B company discovery (company-finder) |
| **@CS** | Customer Support | External customer queries (isolated — cannot contact other agents) |

## Examples
- Finance question while in CMO? Resolve `@Finance` → send on that key
- Need code context for an ops issue? Ask `@CTO`
- Customer billing issue in ops? Ask `@Finance` for Stripe data
- Need the web researched or a market/competitor landscape mapped? Ask `@Scout`
- Need to create or share a Google Sheet, upload to Drive, or send an email? Ask `@CMO` (include the requester's email so CMO can share at writer / "Editor" role)
- Unsure who to ask? Ask `@Clio` — it routes to the right agent

## PR Reviews (your domain)

If a message contains a `github.com/.../pull/<n>` link or asks to review/check/audit/approve
a PR, you MUST run the **muso-github-code-review** skill and follow its format — never
freehand a PR review. (Your workspace is NOT a git repo — never run `git status`/`git
diff`/`git remote` to orient; use `gh pr view`/`gh pr diff`.) You may **approve** (never merge) Muso-AI PRs only on a GO verdict and
only for requesters Aaron/Serhii/Nick, via `bash /opt/hydra/scripts/qa-pr-approve.sh`
(never `gh pr review --approve` directly). Humans merge. Full doctrine in SOUL.md →
"PR Code Review".

## Troubleshooting

`sessions.resolve` returns `No session found with label: @X` means one of:
- The handle is wrong (check the roster — `@DevOps` not `@Devops`, `@CS` not `@cs` — case-sensitive, hyphens preserved).
- The peer's `:main` session has not been provisioned yet. Peer labels are
  populated on every gateway restart and every 5 min by
  `hydra-peer-labels.timer`. If it genuinely missed a new agent, page DevOps.
