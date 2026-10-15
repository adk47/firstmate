# hydra lessons

Distilled, evidence-backed lessons from operating the hydra OpenClaw agent fleet.
These ship with the repo so a fresh clone carries the same hard-won knowledge,
rather than leaving it in one operator's local notes.

Where this sits relative to the rest of the docs:

- `AGENTS.md` (repo root; `CLAUDE.md` imports it) is the short, always-loaded doctrine agents follow.
- `docs/runbooks/RUNBOOK.md` is the step-by-step operate / troubleshoot / recover procedure.
- This `docs/lessons/` cluster is the detailed "what bites you and why" reference
  behind both. When `AGENTS.md` or the RUNBOOK states a rule tersely, the reasoning
  and the failure history live here.

These files are curated, not a memory dump: they capture durable mechanisms and
gotchas, not point-in-time status. Specific model names, versions, and PR numbers
appear only as dated examples, never as the rule. Re-verify anything that smells
stale against the live system before acting on it.

## The files

- **[working-in-hydra.md](working-in-hydra.md)**: how we work here. PR and git
  workflow; enforcement philosophy (prose is not enforcement, build a mechanical
  layer); safety and destructive ops; bash / jq / SQLite / code traps; content and
  domain rules; security posture.
- **[openclaw-and-codex.md](openclaw-and-codex.md)**: the platform. OpenClaw
  gateway, config, skills, cron, plugins, MCP; and the Codex / OAuth runtime. The
  four canonical codex failure modes stay in `CLAUDE.md` and the RUNBOOK; this file
  cross-links them and documents the rest.
- **[deploy-ci-pr.md](deploy-ci-pr.md)**: shipping. Why deploys, CI, and PRs go
  red, and what is real versus noise (including a "red but not your fault" catalog
  of known false signals).
- **[disaster-recovery.md](disaster-recovery.md)**: the two-layer heal stack.
  Code-first detection/heal, the "AI-decides, code-executes" escalator
  (`dr-ai-healer.sh`), why every guardrail exists (trigger→action authorization,
  live-state preconditions, silent-degradation-proof "healed", fresh-window
  strikes, blast-radius rails), and the critical-page mention doctrine.
- **[muso-domain.md](muso-domain.md)**: the business. Muso admin API and muso-cli;
  Trino and analytics; Intercom; NocoDB and ClickUp; Slack rendering; the Caroline
  support agent; people and roles.

## Related

Specialist subagents that carry this knowledge live in `.claude/agents/`. Start with
`hydra-operator` for cross-cutting "what will bite me?" questions; it routes to
`openclaw-expert` (deep gateway/runtime), `hydra-extension-picker` (where does this
go?), `hydra-skill-author`, and `hydra-plugin-author` for narrow authoring work.
