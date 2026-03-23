# Clio → HYDRA Population Plan

> Complete inventory of everything on Clio and where it goes in HYDRA.

## Status Key
- [x] Done
- [ ] Pending
- [~] Partial

---

## 1. API Keys & Credentials → Vault

**Status**: [~] In progress (agent storing to Vault now)

All keys from `~/.zshrc` and `~/.openclaw/.env` → `secret/muso-prod/hydra-integrations/{service}`

| Service | Vault Path | Agent(s) That Need It |
|---------|-----------|----------------------|
| Stripe | `hydra-integrations/stripe` | Finance, CEO, Operations |
| ClickUp | `hydra-integrations/clickup` | CEO, CTO |
| Amplitude | `hydra-integrations/amplitude` | CMO, CEO |
| Klaviyo | `hydra-integrations/klaviyo` | CMO |
| ChartMogul | `hydra-integrations/chartmogul` | Finance, CEO |
| ProfitWell | `hydra-integrations/profitwell` | Finance |
| Intercom | `hydra-integrations/intercom` | Operations |
| Rewardful | `hydra-integrations/rewardful` | CMO, CEO |
| GHL | `hydra-integrations/ghl` | CMO |
| n8n | `hydra-integrations/n8n` | CMO, CTO |
| Cloudflare | `hydra-integrations/cloudflare` | DevOps |
| MongoDB Atlas | `hydra-integrations/mongodb` | CTO, DevOps |
| Webshare | `hydra-integrations/webshare` | DevOps (Aaron-only) |
| Clay | `hydra-integrations/clay` | CMO |
| Google/gog | `hydra-integrations/google` | CEO, CMO |
| Notion | `hydra-integrations/notion` | CEO |
| Figma | `hydra-integrations/figma` | Design |
| Orshot | `hydra-integrations/orshot` | Design, CMO |
| DocuSign | `hydra-integrations/docusign` | CEO, CMO |
| Deel | `hydra-integrations/deel` | Finance |
| Anrok | `hydra-integrations/anrok` | Finance |
| Retool | `hydra-integrations/retool` | Operations |
| Knock | `hydra-integrations/knock` | (disabled) |
| GitHub PAT | `hydra-integrations/github` | All (via CI/CD) |

---

## 2. Core Workspace Files → Agent Workspaces

| Clio File | Size | Target Agent(s) | What To Extract |
|-----------|------|-----------------|-----------------|
| `SOUL.md` | — | [x] Already ported to all agents | Identity, rules, security |
| `TOOLS.md` | — | [x] Already ported to relevant agents | API configs, channel routing |
| `AGENTS.md` | — | [x] Already ported to all agents | Session management, routing |
| `USER.md` | — | [x] Adapted per agent | Owner/team info |
| `MEMORY.md` | 331 lines | [~] Being distributed now | See Section 3 below |
| `SECURITY.md` | — | [x] Coordinator has it | Access tiers, social engineering |
| `HEARTBEAT.md` | 129 lines | [ ] CMO, DevOps, Finance, Ops | Automated tasks (see Section 4) |
| `INTEGRATIONS.md` | 91 lines | [ ] All agents (filtered per domain) | Integration access index |
| `EVIDENCE_STRATEGY.md` | 45 lines | [ ] CEO, CTO | Research methodology |
| `FEEDBACK.md` | 46 lines | [ ] CEO | Interaction feedback patterns |
| `IDENTITY.md` | — | [x] CEO (Clio personality) | Muse of History identity |
| `API-CONFIGS.md` | — | [ ] Per agent via TOOLS.md | API endpoint details |

---

## 3. Memory Distribution (MEMORY.md) → Per-Agent

**Status**: [~] Agent running now

| Memory Section | Target Agent | Priority |
|----------------|-------------|----------|
| Aurora PostgreSQL Usage Map | CTO, DevOps | HIGH |
| Analytics & Data Ops (full technical) | CTO | HIGH |
| Fede Working Rules (ALL) | CMO | CRITICAL |
| B2B Hard Lessons (ALL) | CMO | CRITICAL |
| B2B-Ads-Clio Pipeline | CMO | HIGH |
| Recurring Invoices | Finance | HIGH |
| Invoice Creation Rules (ACH) | Finance | HIGH |
| Payout Report Requirements | Finance | HIGH |
| Stripe Product Map | Finance | HIGH |
| People Quick Reference | CEO, Coordinator | HIGH |
| Terminology (Pro/Business/Ads) | CEO, CMO | MEDIUM |
| Credit Request Audit Trail | Operations, QA | MEDIUM |
| Retool Replacement Context | Operations | MEDIUM |
| Athena Patterns | CTO | MEDIUM |
| Infra Pulse Rule | DevOps, Coordinator | MEDIUM |
| Infrastructure Notes | DevOps | MEDIUM |
| Message Attribution | Coordinator | MEDIUM |
| Andrey's Rules (historical) | CTO | LOW |
| Slack↔CU Gap Analysis | CEO | LOW |
| Browser Screenshot Paths | Design | LOW |

---

## 4. HEARTBEAT.md → Per-Agent Automations (PAUSED)

**Status**: [ ] Not started — these must be migrated but KEPT DISABLED until cutover

| Automation | Clio Schedule | Target Agent | Risk |
|-----------|--------------|-------------|------|
| B2B Reply Scanner | Every 15 min | CMO | CRITICAL |
| B2B Daily Reply + GHL Sync | Daily | CMO | CRITICAL |
| B2B Monday Batch Prep | Mondays | CMO | CRITICAL |
| B2B Follow-up Check | Daily | CMO | CRITICAL |
| Win-Back Engine | 3x daily | CMO | CRITICAL |
| Fede's EOD Briefing | 22:00 CET | CMO | MEDIUM |
| AMP Daily Report | 11am CST | CMO | MEDIUM |
| Meeting Booked Notification | Continuous | CMO | HIGH |
| Daily Finance Heartbeat | Daily AM | Finance | HIGH |
| Daily Claiming Report | Daily AM | Operations | HIGH |
| Daily Credit Fraud Scan | Daily | Operations | HIGH |
| Refund Processor (channel skill) | On-demand | Operations | CRITICAL |
| Commit Review | Daily | DevOps | MEDIUM |
| Industry Import Freshness | Daily | DevOps | MEDIUM |
| AWS Infrastructure Monitoring | Daily | DevOps | MEDIUM |
| Webshare Proxy Health | Daily | DevOps | MEDIUM |
| GitHub Key Leak Scan | 3x daily | DevOps | HIGH |
| Daily Write Activity Report | Daily | DevOps | MEDIUM |
| Daily PR Code Review | Daily 7am PST | DevOps/CTO | MEDIUM |
| Nightly Slack↔CU Gap | 00:00 PST | CEO | LOW |
| Weekly Comm Scorecard | Mon 9am PST | CEO | LOW |
| Dev Activity Report | 00:00 PST | CEO | LOW |

---

## 5. Skills (47 total) → Per-Agent

**Status**: [x] Skills already distributed as independent copies

| Agent | Skills Count | Skills |
|-------|-------------|--------|
| CEO | 10 | muso-clio, muso-clickup, muso-chartmogul, muso-stripe, muso-amplitude, muso-rewardful, muso-query-writer, dev-activity-report, humanizer, muso-slack-formatter |
| CMO | 12 | muso-clio, muso-amplitude, muso-klaviyo, muso-ads-manager, muso-b2b-copywriter, muso-outreach-engine, muso-winback-engine, muso-winback-pro, muso-rewardful, muso-slack-formatter, cmo-eod, humanizer |
| CTO | 10 | muso-clio, muso-architect, muso-data-expert, muso-devops, muso-query-writer, muso-cloudflare, muso-n8n, muso-credit-investigator, muso-slack-formatter, dev-activity-report |
| QA | 4 | muso-clio, muso-verify-profile, muso-credit-investigator, muso-slack-formatter |
| Finance | 12 | muso-stripe, muso-stripe-disputes, muso-stripe-payout-enricher, muso-stripe-payout-report, muso-chartmogul, muso-profitwell, muso-anrok, muso-deel, muso-contract-invoicer, muso-refund-investigation, muso-refund-processor, muso-slack-formatter |
| Operations | 14 | muso-ops-admin through muso-ops-workspaces (10), muso-intercom, muso-refund-processor, muso-refund-investigation, muso-slack-formatter |
| DevOps | 7 | muso-devops, muso-cloudflare, muso-n8n, muso-query-writer, gateway-self-heal, muso-workspace-sync, muso-slack-formatter |
| Design | 3 | muso-clio, humanizer, muso-slack-formatter |
| Coordinator | 1 | muso-slack-formatter |
| CS (Support) | 4 | profile_lookup, credits_search, subscription_status, create_ticket (custom, not from Clio) |

**Note**: Skills with reference data (muso-clio: 90 files, muso-query-writer: 259 files) are already copied with all their reference subdirectories.

---

## 6. Reference Data → Per-Agent Skills

| Clio Reference Dir | Files | Target | Status |
|-------------------|-------|--------|--------|
| `muso-clio/references/core-backend/` | 6 files | CTO | [x] In skills |
| `muso-clio/references/devops/` | 6 files | DevOps, CTO | [x] In skills |
| `muso-clio/references/industry-data/` | 8 files | CTO | [x] In skills |
| `muso-clio/references/analytics-worker/` | 4+ files | CTO | [x] In skills |
| `muso-clio/references/business/` | 4 files | CEO | [x] In skills |
| `muso-clio/references/klaviyo/` | 1 file | CMO | [x] In skills |
| `muso-clio/references/data-model/` | ? files | CTO | [x] In skills |
| `muso-clio/references/operations/` | ? files | Operations | [x] In skills |
| `muso-query-writer/` | 259 files (SQL) | CTO | [x] In skills |
| `muso-ads-manager/references/` | 2 files | CMO | [x] In skills |
| `muso-winback-pro/` | 6 files | CMO | [x] In skills |
| `muso-docusign/` | 6 files | CEO | [x] In skills |

---

## 7. Workspace Data Files (CSV/JSON) → Archive

These are transient work products, not config. Archive to hydra-audit, don't migrate.

| File | Purpose | Action |
|------|---------|--------|
| `payout-report-*.csv` (5 files) | Historical payout reports | Archive to Finance memory |
| `credit-revert-*.json/csv` | Credit revert batches | Archive to Operations memory |
| `churned_campaign_data_v2.csv` | Churn analysis | Archive to CMO memory |
| `unclaimed_users.csv` | Unclaimed user list | Archive to Operations |
| `amp-report-raw.csv` | AMP advertising data | Archive to CMO |
| `disputes_raw.json` | Stripe disputes | Archive to Finance |
| `muso-ads-form-workflow-final.json` | AMP workflow config | Copy to CMO skills |

---

## 8. Plans & Specs → Per-Agent Reference

| File | Target Agent | Priority |
|------|-------------|----------|
| `plans/multi-agent-architecture.md` | CEO | Done (this IS HYDRA) |
| `plans/ADR-014-cloudflare-everything.md` | DevOps | MEDIUM |
| `plans/fix-materialize-industry-spark-failure.md` | CTO | MEDIUM |
| `plans/web-credits-overhaul-prompt.md` | CTO | LOW |
| `plans/muso-ads-form-v3.md` | CMO | MEDIUM |
| `plans/cloudflare-migration-impact-plan.md` | DevOps | LOW |
| `specs/` | CTO | Review and distribute |

---

## 9. Workspace Reference Files

| File | Target | Priority |
|------|--------|----------|
| `reference/retool-replacement-plan.md` | Operations | HIGH |
| `reference/liza-payout-format.md` | Finance | HIGH |
| `reference/pipeline-architecture-audit.md` | CTO | MEDIUM |
| `reference/recurring-invoices.md` | Finance | HIGH |

---

## 10. Daily Memory Files (44 files) → Process & Archive

These contain raw daily operational logs. Process for lasting lessons, archive the rest.

**Action**: Scan all 44 daily files. Extract any lessons not already in MEMORY.md. Add to relevant agent's MEMORY.md. Archive originals to hydra-audit.

---

## 11. Special Files

| File | Target | Action |
|------|--------|--------|
| `outreach/` dir | CMO | Copy B2B outreach templates and reports |
| `finance/` dir | Finance | Copy financial reports and templates |
| `audit-batches/` dir | Operations | Copy audit batch data |
| `mxwtm-assets/` dir | CEO | Marketing assets |
| `figma-amp-plugin/` dir | Design | Figma plugin source |
| `scripts/` dir | DevOps | Operational scripts |
| `queries/` dir | CTO | Saved Athena queries |

---

## Execution Order

1. **[x] API Keys → Vault** (agent running now)
2. **[~] MEMORY.md → per-agent** (agent running now)
3. **[ ] HEARTBEAT.md → per-agent** (create as disabled tasks)
4. **[ ] INTEGRATIONS.md → per-agent TOOLS.md** (filter by domain)
5. **[ ] Reference files → per-agent skills**
6. **[ ] Workspace data → archive**
7. **[ ] Daily memory files → scan and extract**
8. **[ ] Plans/specs → per-agent reference**
9. **[ ] Outreach/finance/audit dirs → per-agent**
10. **[ ] Verify each agent has everything it needs**
11. **[ ] Shadow test each agent against Clio responses**
