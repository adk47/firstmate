# HYDRA Docs

Documentation for **HYDRA** — the OpenClaw agent fleet on OVH node-8 (see the
[root README](../README.md) for the project overview, and [`CLAUDE.md`](../CLAUDE.md)
for the operating doctrine that agents follow).

Docs are grouped by purpose. Operational truth lives in **Runbooks**; durable
how-to in **Guides**; system shape in **Reference**; point-in-time records in
**Designs**, **Superpowers**, and **Archive**. A `⚠` marks a doc whose *content*
is known to be partly stale (kept for history; not yet refreshed).

## Guides — durable how-to
- [ONBOARDING.md](guides/ONBOARDING.md) ⚠ — getting started as an agent owner / admin / developer (v1.0, Mar 2026)
- [CS-AGENT-DEVELOPER-GUIDE.md](guides/CS-AGENT-DEVELOPER-GUIDE.md) — developing the CS/Caroline agent
- [REPO-MANAGEMENT.md](guides/REPO-MANAGEMENT.md) ⚠ — dependency & release strategy (OpenClaw version line is stale; see `scripts/deploy.sh`)
- [WORKSPACE-FILE-OWNERSHIP.md](guides/WORKSPACE-FILE-OWNERSHIP.md) — deploy-owned vs agent-owned workspace files

## Reference — system shape & policy
- [ARCHITECTURE.md](reference/ARCHITECTURE.md) ⚠ — the fleet's system architecture (v1.0, Mar 2026)
- [GOVERNANCE.md](reference/GOVERNANCE.md) — agent ownership, security boundaries, branch protection

## Runbooks — operate, troubleshoot, recover
- [RUNBOOK.md](runbooks/RUNBOOK.md) — the main operational runbook (deploy, troubleshooting, incident recovery)
- [RUNBOOK-outreach-sender-worker.md](runbooks/RUNBOOK-outreach-sender-worker.md) — CMO outreach sender worker failure modes

## Credit Verification — the fraud/credit-verification subsystem
Start at the cluster index: [credit-verification/README.md](credit-verification/README.md).
- [design.md](credit-verification/design.md) · [operations.md](credit-verification/operations.md) · [lessons.md](credit-verification/lessons.md)
- [fraud-detection-spec.md](credit-verification/fraud-detection-spec.md) · [fraud-issue-db-state.md](credit-verification/fraud-issue-db-state.md) · [fraud-issue-scorer-followups.md](credit-verification/fraud-issue-scorer-followups.md)
- Research/audits: [credit-claim-proof-audit-2026-05-19.md](credit-verification/credit-claim-proof-audit-2026-05-19.md) · [credit-fleet-fraud-backend-recommendations.md](credit-verification/credit-fleet-fraud-backend-recommendations.md) · [browser-tooling-research](credit-verification/credit-verification-browser-tooling-research-2026-05-04.md) · [runlog-bypass](credit-verification/credit-verification-runlog-bypass-2026-05-04.md) · [subagent-debug](credit-verification/credit-verification-subagent-debug-2026-05-01.md)

## Designs — point-in-time design & plan records
Dated snapshots of a feature's design at the time it was built (not kept current):
- [2026-03-23 — intercom channel plugin](designs/2026-03-23-intercom-channel-plugin-design.md)
- [2026-04-12 — CS experience improvement (design)](designs/2026-04-12-cs-experience-improvement-design.md) · [(plan)](designs/2026-04-12-cs-experience-improvement-plan.md)
- [2026-04-17 — CS agent email guardrail](designs/2026-04-17-cs-agent-email-guardrail-design.md)
- [2026-04-21 — CS experience overhaul](designs/2026-04-21-cs-experience-overhaul-design.md)
- [2026-05-04 — intercom bot self-protection](designs/2026-05-04-intercom-bot-self-protection-design.md)
- [2026-06-01 — Caroline safe credit dedupe](designs/2026-06-01-caroline-safe-credit-dedupe-design.md)
- [2026-06-02 — QA autofix loop (design)](designs/2026-06-02-qa-autofix-loop-design.md) · [(part-A plan)](designs/2026-06-02-qa-autofix-loop-part-a-plan.md)
- [2026-06-04 — Caroline daily review](designs/2026-06-04-caroline-daily-review-design.md)
- [2026-06-11 — Caroline Block Kit weekly](designs/2026-06-11-caroline-blockkit-weekly-design.md)
- [2026-06-16 — muso CLI unification migration plan](designs/2026-06-16-muso-cli-unification-migration-plan.md)

## Superpowers — plan/spec pairs from the superpowers workflow
Each feature has a **spec** (the contract) and a **plan** (the build steps). Referenced by CI and scripts — do not relocate.

| Feature | Spec | Plan |
|---|---|---|
| Credit-verification workflow | [spec](superpowers/specs/2026-03-27-credit-verification-workflow-design.md) | [plan](superpowers/plans/2026-03-27-credit-verification-workflow.md) |
| Intercom handoff persistence | [spec](superpowers/specs/2026-04-02-intercom-handoff-persistence-design.md) | [plan](superpowers/plans/2026-04-02-intercom-handoff-persistence.md) |
| Refund retention | [spec](superpowers/specs/2026-04-03-refund-retention-design.md) | [plan](superpowers/plans/2026-04-03-refund-retention.md) |
| CMO outreach sender worker | [spec](superpowers/specs/2026-04-14-cmo-outreach-sender-worker-design.md) | [plan](superpowers/plans/2026-04-14-cmo-outreach-sender-worker.md) |
| Intercom bot self-protection | — | [plan](superpowers/plans/2026-05-04-intercom-bot-self-protection.md) |
| Caroline analytics knowledge base | [spec](superpowers/specs/2026-05-08-caroline-analytics-knowledge-base-design.md) | [plan](superpowers/plans/2026-05-08-caroline-analytics-knowledge-base.md) |
| Caroline analytics handoff | [spec](superpowers/specs/2026-05-11-caroline-analytics-handoff-design.md) | [plan](superpowers/plans/2026-05-11-caroline-analytics-handoff.md) |
| Caroline RAG | [spec](superpowers/specs/2026-05-14-caroline-rag-design.md) | [plan](superpowers/plans/2026-05-14-caroline-rag.md) |
| Caroline weekly review | [spec](superpowers/specs/2026-05-14-caroline-weekly-review-design.md) | [plan](superpowers/plans/2026-05-14-caroline-weekly-review.md) |

## Archive — completed / historical (kept for the record)
- [MIGRATION-CUTOVER-PLAN.md](archive/MIGRATION-CUTOVER-PLAN.md) — Clio → HYDRA migration plan (completed Mar 2026)
- [CLIO-TO-HYDRA-POPULATION-PLAN.md](archive/CLIO-TO-HYDRA-POPULATION-PLAN.md) — Clio inventory & destination map (completed)
- [VOICE-PLAN.md](archive/VOICE-PLAN.md) — proposed self-hosted voice interface (not shipped)

## Assets
- [cs-slack-manifest.json](assets/cs-slack-manifest.json) — Slack app manifest for the CS agent
