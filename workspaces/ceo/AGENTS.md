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

## Credentials

Credentials come from the **gateway environment** – loaded as a systemd
`EnvironmentFile` by your gateway unit (`/etc/openclaw/main.env` for
`openclaw-gateway-main`, `/etc/openclaw/edge.env` for `openclaw-gateway-edge`)
and inherited by every codex child of that unit (a shell you started yourself
over SSH is not one: it sources your profile instead). They are **NOT** in `~/.zshrc`: the gateway
runs as a daemon and does not source an interactive shell, so sourcing your
shell profile does nothing for you. If a variable is unset or the API returns
401/403, tell DevOps which variable and which unit, and do not wait for a
reply. Carry on with the work that does not need it, and stop only the
actions that do. A check you could not run never counts as passed.
`openclaw__secrets request` is not a shortcut around that: a requested value
goes straight to the team store and is never given to your shell or your
chat, so it cannot satisfy a `$VAR` your command reads. Never request a name
that is, or should be, in the gateway env; DevOps sets those in the unit env
file.

## Watch-Crons — Self-Re-Arming One-Shots Only

If you create a cron to watch for a condition (e.g. "has this customer's
removed credit been restored yet"), it must be a self-re-arming **one-shot**,
never a recurring schedule. Each main deploy reconciles the live cron store to
`cron-jobs.json` by delete-and-reinsert, so ANY recurring cron you create with
`openclaw cron add` and never commit to the repo would be deleted on the next
deploy — so the guard halts the deploy instead, and it halts every deploy for
everyone until the recurring cron is dealt with (MUS-1139: six days, two
monitors, one manual host intervention).

The fix: each turn, if the awaited condition isn't met yet, arm the next
one-shot ~10 minutes out and exit —
`openclaw cron add --at "+600s" --session isolated --message "..." ...`
(`--at` defaults `deleteAfterRun:true`). That exact shape — `deleteAfterRun`
is `true` AND `schedule.kind` is `"at"` — is what both deploy guards treat as
ephemeral and exempt; a recurring `schedule.kind` of `"cron"` or `"every"`
is NOT exempt, even with `deleteAfterRun:true` set. Do not use a recurring
schedule for a watch-cron, and do not ask DevOps for a guard exemption —
there isn't one that doesn't amount to "delete it on the next deploy anyway."
Known cost: a deploy landing between arm and fire deletes the pending
one-shot and the chain silently stops — acceptable because you're already
blocked awaiting that condition, so the loss surfaces on your own card.

## Troubleshooting

`sessions.resolve` returns `No session found with label: @X` means one of:
- The handle is wrong (check the roster — `@DevOps` not `@Devops`, `@CS` not `@cs` — case-sensitive, hyphens preserved).
- The peer's `:main` session has not been provisioned yet. Peer labels are
  populated on every gateway restart and every 5 min by
  `hydra-peer-labels.timer`. If it genuinely missed a new agent, page DevOps.
