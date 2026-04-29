# HYDRA Architecture

> **Version**: 1.0 | **Date**: 2026-03-22 | **Author**: Aaron (adk47)
>
> HYDRA (Hyper-Unified Distributed Reasoning Architecture) is a 9-agent AI assistant system
> running on a dedicated OVH bare-metal server. It replaces the single-agent system called Clio.

---

## Table of Contents

1. [Physical Infrastructure](#physical-infrastructure)
2. [System Architecture](#system-architecture)
3. [Four-Layer Security Stack](#four-layer-security-stack)
4. [Data Flow](#data-flow)
5. [Agent-Slack Mapping](#agent-slack-mapping)
6. [Agent Workspace Structure](#agent-workspace-structure)
7. [Model Strategy](#model-strategy)
8. [Infrastructure Integration](#infrastructure-integration)
9. [Backup Strategy](#backup-strategy)

---

## Physical Infrastructure

| Property          | Value                                             |
|-------------------|---------------------------------------------------|
| **Server**        | Node 8 (OVH ADVANCE-3)                           |
| **CPU**           | AMD EPYC 4464P 16 cores / 32 threads             |
| **RAM**           | 64 GB DDR5                                        |
| **Storage**       | 2 x 960 GB NVMe                                  |
| **Network**       | 25 Gbps                                          |
| **Public IP**     | 40.160.32.80                                      |
| **vRack IP**      | 10.0.0.8                                          |
| **Datacenter**    | Vint Hill, VA (vin1)                              |
| **Cluster Role**  | K3s agent node in 8-node cluster                  |
| **K3s Taint**     | `dedicated=hydra:NoSchedule`                      |
| **Monthly Cost**  | $217                                              |

Node 8 is part of the broader Muso OVH infrastructure (8-node K3s cluster), but the HYDRA
gateway itself runs as a Docker container -- not as a K8s pod. This is required by the
NemoClaw/OpenShell kernel-level sandbox, which needs direct Docker socket access.

---

## System Architecture

```
Internet
    |
    +-- Slack API (WebSocket, Socket Mode)
    |       |
    |       v
    |   +------------------------------------------------------+
    |   |  Node 8 (40.160.32.80 / 10.0.0.8)                   |
    |   |                                                       |
    |   |  +------------------------------------------------+  |
    |   |  |  NemoClaw/OpenShell Sandbox                     |  |
    |   |  |  (Docker container: hydra-sandbox)              |  |
    |   |  |  User: sandbox (uid 998)                        |  |
    |   |  |                                                  |  |
    |   |  |  +------------------------------------------+   |  |
    |   |  |  |  OpenClaw Gateway v2026.3.13             |   |  |
    |   |  |  |  Port 18789 (localhost only)             |   |  |
    |   |  |  |                                          |   |  |
    |   |  |  |  9 Agents:                               |   |  |
    |   |  |  |    coordinator  (Buddy)   - Opus 4.7     |   |  |
    |   |  |  |    ceo                    - Opus 4.7     |   |  |
    |   |  |  |    cmo                    - Opus 4.6 *   |   |  |
    |   |  |  |    cto                    - Opus 4.7     |   |  |
    |   |  |  |    qa                     - Sonnet       |   |  |
    |   |  |  |    finance                - Intelligent  |   |  |
    |   |  |  |    operations             - Kimi K2.6    |   |  |
    |   |  |  |    devops                 - Sonnet       |   |  |
    |   |  |  |    design                 - Intelligent  |   |  |
    |   |  |  |    (* cmo migrating to 4.7 via PR #131)  |   |  |
    |   |  |  +-------------------+----------------------+   |  |
    |   |  |                                                  |  |
    |   |  +--------------------------------------------------+  |
    |   |                                                        |
    |   |  +----------------------------------------------+      |
    |   |  |  iptables Firewall                           |      |
    |   |  |  Default: DENY all inbound                   |      |
    |   |  |  Allow: SSH, vRack (10.0.0.0/24), K3s ports  |      |
    |   |  +----------------------------------------------+      |
    |   +------------------------------------------------------+
    |
    +-- OpenRouter (openrouter.ai)
    |       ^ Claude (Opus 4.7 / Sonnet 4.6 / Haiku) + GPT-5.5 / 5.4-mini — sole inference path
    |
    +-- GitHub (Muso-AI/hydra, Muso-AI/hydra-audit)
```

### Key Components

| Component         | Container Name   | Port       | Purpose                                      |
|-------------------|------------------|------------|----------------------------------------------|
| OpenClaw Gateway  | hydra-sandbox    | 18789      | Multi-agent orchestration, Slack integration  |
| NemoClaw/OpenShell| (wraps hydra-sandbox) | --    | Kernel-level sandboxing (Landlock, seccomp)   |

---

## Four-Layer Security Stack

HYDRA uses a defense-in-depth approach with four security layers:

### Layer 0: NemoClaw/OpenShell (Kernel-Level Sandbox)

The innermost layer provides OS-level isolation for the agent runtime.

| Mechanism     | What It Does                                                      |
|---------------|-------------------------------------------------------------------|
| **Landlock**  | Filesystem read-only by default; agents can only write to their own workspace |
| **seccomp**   | System call filtering -- blocks dangerous syscalls (ptrace, mount, etc.) |
| **netns**     | Network namespace isolation -- agents share no network with host  |
| **L7 Policies** | Layer-7 network policies control which domains agents can reach |
| **Non-root**  | All agent processes run as user `sandbox` (uid 998)               |

### Layer 1: OpenRouter (Single Inference Endpoint)

All model traffic — Claude *and* GPT — is funneled through OpenRouter.

- Agents only have egress to `openrouter.ai`; direct Anthropic / OpenAI / Fireworks reach is disallowed by the egress allowlist
- A single API key (`OPENROUTER_API_KEY`) gates every model call across every profile
- OpenRouter's per-key dashboard provides per-call request logs
- Model-ID convention: `openrouter/<provider>/<model-id>` (e.g. `openrouter/anthropic/claude-opus-4.7`, `openrouter/openai/gpt-5.5`)

### Layer 2: OpenClaw Gateway (Agent Management)

The orchestration layer enforces per-agent boundaries.

- **Per-agent workspaces**: each agent has isolated config files
- **SOUL.md rules**: behavioral guardrails baked into agent identity (read-only)
- **Tool deny lists**: agents can only use approved tools
- **Channel bindings**: agents only respond in their assigned Slack channels
- **Agent isolation**: agents cannot read each other's workspaces

### Layer 3: eDiscovery (Audit Trail)

Complete governance and compliance layer.

- Every agent interaction is logged to an audit buffer
- Hourly git commits pushed to the `Muso-AI/hydra-audit` repository
- Governance alerts fire on policy violations
- Full replay capability for any conversation

---

## Data Flow

The end-to-end path of a user message through HYDRA:

```
1. User posts message in Slack channel
       |
       v
2. Slack delivers via Socket Mode WebSocket --> OpenClaw Gateway
       |
       v
3. Gateway identifies which agent owns the Slack app that received the message
   (each agent = its own Slack app with unique bot token + app-level token)
       |
       v
4. Agent loads its workspace files:
   - SOUL.md   --> identity, behavioral rules, deny lists
   - AGENTS.md --> awareness of other agents
   - TOOLS.md  --> available tool configurations
   - USER.md   --> who is talking to it
   - MEMORY.md --> learned context from past interactions
       |
       v
5. Agent constructs inference request
       |
       v
6. Request --> OpenRouter (openrouter.ai) --> upstream provider --> response
       |
       v
7. Agent posts response back to Slack channel
       |
       v
8. Interaction logged to audit buffer --> hourly git push to hydra-audit
```

### Important: No Central Router

Unlike typical multi-agent systems, HYDRA does **not** have a central message router.
Each agent IS a Slack app. When a user mentions @Buddy or @CEO, Slack delivers the
message directly to that agent's WebSocket connection. This is simpler and more resilient
than a hub-and-spoke architecture.

---

## Agent-Slack Mapping

Each of the 9 agents is a separate Slack application with its own identity.

| Agent ID      | Slack Name | Model        | Owner   | Primary Role                          |
|---------------|------------|--------------|---------|---------------------------------------|
| coordinator   | @Buddy     | Opus 4.7     | Aaron   | Triage, coordination, general help    |
| ceo           | @CEO       | Opus 4.7     | Fede    | Strategy, business decisions          |
| cmo           | @CMO       | Opus 4.6 *   | Nick    | Marketing, growth, communications     |
| cto           | @CTO       | Opus 4.7     | Jay     | Technical leadership, architecture    |
| qa            | @QA        | Sonnet 4.6   | Liza    | Testing, quality assurance            |
| finance       | @Finance   | Intelligent  | Jan     | Financial analysis, budgeting         |
| operations    | @Operations| Kimi K2.6    | Artem D | Operational workflows, logistics      |
| devops        | @DevOps    | Sonnet 4.6   | Aaron   | Infrastructure, CI/CD, deployments    |
| design        | @Design    | Intelligent  | Mariia  | UI/UX, design systems, assets         |

\* cmo is migrating to Opus 4.7 via PR #131 (dedicated `anthropic-cmo` provider for isolated API key).

### How Channel Membership Works

- Each agent's Slack app is added to specific channels
- An agent can only see and respond to messages in channels it belongs to
- DMs go directly to the specific agent
- Mentioning an agent in a channel it is not in will not reach it

---

## Agent Workspace Structure

Every agent has an isolated workspace directory under `/opt/hydra/workspaces/`:

```
/opt/hydra/workspaces/{agent}/
|-- SOUL.md        (444, read-only)  -- Identity, behavioral rules, tool deny lists
|-- AGENTS.md      (444, read-only)  -- Knows about other agents, delegation rules
|-- TOOLS.md       (444, read-only)  -- Tool configurations and capabilities
|-- USER.md        (644, writable)   -- Owner/team info, preferences
|-- MEMORY.md      (644, writable)   -- Learned context from conversations
+-- skills/        (444, read-only)  -- Skill definitions and templates
```

### File Permissions

| File       | Mode | Who Can Change It                              |
|------------|------|------------------------------------------------|
| SOUL.md    | 444  | Aaron only (via PR with approval)              |
| AGENTS.md  | 444  | Aaron only (via PR with approval)              |
| TOOLS.md   | 444  | Aaron only (via PR with approval)              |
| USER.md    | 644  | Agent owner (via PR, self-merge OK)            |
| MEMORY.md  | 644  | Agent itself (auto-written) or owner (via PR)  |
| skills/    | 444  | Aaron only (via PR with approval)              |

The read-only (444) files are the security boundary. An agent cannot modify its own
SOUL.md, which means it cannot change its own rules, bypass deny lists, or alter its
identity. These files are mounted read-only in the NemoClaw sandbox.

---

## Model Strategy

HYDRA uses a tiered model allocation to balance capability with cost.

### Fixed Assignments (7 agents)

All inference is routed via OpenRouter. The current workload-driven matrix
(see `openclaw-main.json`, `agents.list[]`) primary assignments:

| Provider/Model                                        | Agents (primary)                          | Rationale                       |
|-------------------------------------------------------|-------------------------------------------|---------------------------------|
| `openrouter/anthropic/claude-opus-4.7`                | clio, cmo, finance                        | Complex reasoning, strategy     |
| `openrouter/openai/gpt-5.5`                           | ceo, cto, qa, operations, devops, design, support | Cost/latency-balanced default   |
| `openrouter/anthropic/claude-4.6-sonnet-20260217`     | imageModel default; ops fallback          | Multimodal + analysis           |
| `openrouter/anthropic/claude-haiku-latest`            | imageModel + support fallback             | Cheap fast fallback             |

### Intelligent Selection (2 agents)

The `finance` and `design` agents use intelligent model selection
that picks the right model based on task complexity:

| Model          | Approximate Usage | When Selected                        |
|----------------|-------------------|--------------------------------------|
| Haiku 4.5      | ~60%              | Simple lookups, formatting, FAQs     |
| Sonnet 4.6     | ~25%              | Analysis, moderate complexity         |
| Opus 4.6       | ~15%              | Deep reasoning, complex decisions     |

This keeps costs down for agents that handle a mix of simple and complex requests.

---

## Infrastructure Integration

Node 8 serves a dual role: it is both a K3s agent node and the HYDRA Docker host.

### What Runs in K3s

- **PVC storage** via Longhorn (workspace persistence, audit logs)
- **CronJobs** for audit commits, health checks, and log rotation
- **Network policies** via Cilium (vRack-only access rules)
- **Secret management** via Vault + External Secrets Operator (ESO)

### What Runs in Docker (Outside K3s)

- **hydra-sandbox** (OpenClaw Gateway inside NemoClaw sandbox)

The gateway MUST run as a Docker container rather than a K8s pod because the
NemoClaw/OpenShell sandbox requires direct control over Linux kernel security
features (Landlock, seccomp, namespaces) that are not available through the
K8s pod security model.

### K3s Node Configuration

```
Node:   ovh-node-8
Role:   K3s agent
Taint:  dedicated=hydra:NoSchedule
Labels: node-role=hydra
```

The `NoSchedule` taint prevents other K8s workloads from being scheduled on Node 8,
reserving its resources for HYDRA.

---

## Backup Strategy

Three tiers of data protection:

| Tier | What                          | Where                        | Frequency       |
|------|-------------------------------|------------------------------|-----------------|
| 1    | hydra repo (config, SOUL.md)  | GitHub (Muso-AI/hydra)       | On every PR merge |
| 1    | Audit trail                   | GitHub (Muso-AI/hydra-audit) | Hourly           |
| 2    | Git bundles of both repos     | OVH Object Storage           | Nightly          |
| 3    | K8s manifests and scripts     | H-DevOps repo                | On change        |

### Recovery

- **Agent config loss**: Re-clone hydra repo, redeploy workspaces
- **Audit data loss**: Re-clone hydra-audit repo (hourly RPO)
- **Node 8 failure**: Provision new server, install Docker + K3s agent, restore from Tier 1
- **Full disaster**: Rebuild from H-DevOps manifests + hydra repo + Vault secrets
