# HYDRA

HYDRA is Muso's multi-agent AI assistant fleet — a set of department-owned agents
(CTO, CMO, Ops, DevOps, Finance, QA, Caroline/CS, …) running on **[OpenClaw](https://openclaw.ai)**
on a dedicated OVH server (**node-8**, `40.160.32.80`). It replaces the earlier
single-agent system, "Clio".

Two gateway processes run the fleet:
- **main** (`openclaw-gateway-main`) — the internal agents, reached over Slack.
- **edge** (`openclaw-gateway-edge`) — **Caroline**, the customer-support agent, reached over Intercom.

## How it ships

- **Deploy** is push-to-`main`: a self-hosted GitHub Actions runner **on node-8**
  runs [`scripts/deploy.sh`](scripts/deploy.sh) (rsync → skills/plugins → restart →
  smoke test → baseline). See the [deploy runbook](docs/runbooks/RUNBOOK.md#deploy).
- **Releases** are cut daily off `main` (`vYYYY.M.D` tags via `scripts/release.sh`);
  GitHub Releases are the changelog.
- **Agent behavior, infra conventions, and the "where does this go?" decision tree**
  live in [`CLAUDE.md`](CLAUDE.md) — read it before adding code.

## Start here

- 📚 **[docs/README.md](docs/README.md)** — the full documentation index
- 🛠️ **[Operational runbook](docs/runbooks/RUNBOOK.md)** — deploy, troubleshoot, recover
- 🏗️ **[Architecture](docs/reference/ARCHITECTURE.md)** — how the fleet is put together
- 🧭 **[Onboarding](docs/guides/ONBOARDING.md)** — for new owners / admins / developers
- ⚖️ **[Governance](docs/reference/GOVERNANCE.md)** — ownership, security boundaries, branch protection
- 🤖 **[CLAUDE.md](CLAUDE.md)** — operating doctrine for agents working in this repo

## Repo layout

| Path | What |
|---|---|
| `scripts/` | deploy, release, watchdogs, self-heal libs (`scripts/lib/`), tests (`scripts/tests/`, bats) |
| `plugins/` | in-tree OpenClaw plugins (intercom, support-tools, …) |
| `skills-all/` | canonical agent SKILLs (shared across agents) |
| `workspaces/<agent>/` | per-agent SOUL.md, skills, and config |
| `docs/` | documentation — see [docs/README.md](docs/README.md) |
| `.github/workflows/` | CI gates + deploy pipeline |
