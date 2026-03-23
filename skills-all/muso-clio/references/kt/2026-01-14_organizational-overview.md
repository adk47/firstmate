# KT Session: Organizational Overview & Team Structure

**Date:** 2026-01-14
**Presenter:** Oleg Mamchich
**Meeting ID:** `2026-01-14_meeting-jan-14-2026-at-19-21-eet`

## Summary

Initial knowledge transfer covering team structure, development processes, and tooling landscape.

---

## Team Structure (as of Jan 2026)

### Growth Team (Product)
Owns user-facing services: onboarding, discography, analytics, payments.

| Person | Role | Ownership |
|--------|------|-----------|
| Si | Full-stack, Team Lead | Growth microservices |
| Ehar | Full-stack | Growth microservices |
| Artto | Mobile Engineer | Flutter (iOS/Android) |

### Platform Team (Data)
Owns data capture, ingestion, and processing pipelines.

| Person | Role | Ownership |
|--------|------|-----------|
| Andre | Senior Data Engineer | 80% of data pipelines, Airflow |
| Oleg | CTO/Engineering Lead | 20% data pipelines, Catalog microservices |

### Catalog Team
Merged into Growth due to team contraction. Catalog microservices primarily owned by Oleg.

---

## Development Process (ClickUp)

### Sprint Structure
- **Two-week sprints**
- **Priority List folder**: Stakeholders define priorities
- **Parent tasks** = Priorities (not epics - have clear end states)
- Tasks linked to priorities, estimated, moved into sprints

### Cross-Team Linking
- Marketing/Sales space: Fedy, Nina define their own tasks
- Tasks can link across spaces

---

## Infrastructure Access

### SSH Tunneling (OPERATIONAL)
- **Two shared SSH keys**: one for dev, one for prod
- All engineers have access for tunneling
- Keys stored in Notion (common commands doc)
- **Note**: Keys not rotated in ~2 years (security debt)

### Databases in RDS Aurora
| Database | Purpose |
|----------|---------|
| `catalog` | Catalog team data |
| `core_backend` | Users, payments, subscriptions |
| `industry_calculations` | Industry data aggregations |
| `stats` | Analytics pre-aggregations |
| `feed` | Feed service data |
| `allup` | (purpose TBD) |

Some SQL grant/connect commands for database setup are NOT in Terraform - documented in Notion only.

---

## Critical Notion Documents

### DevOps Knowledge Transfer (MOST IMPORTANT)
- Created by: Ivan (former DevOps engineer)
- Covers: infrastructure, secrets, AWS EKS deployment
- Status: Still actively used and important

### Event Tracking Document
- **191+ Amplitude events** documented
- Naming convention: `backend_*`, `frontend_*`
- Example: `backend_user_subscription_refund`
- Some events undocumented - ask in Growth team Slack

### Engineering Expectations
Performance measurement framework:
1. **User Focus** - understand user benefit
2. **Delivery** - clarifying questions, realistic expectations, testing
3. **Ownership** - own code, end results, codebase, product

---

## Data Pipeline Development

### PRD/Formula Process
- Oleg creates MD file PRDs in repo (moved away from Notion)
- Template includes data transformation formulas
- Andre picks up and implements
- Works well with LLMs (Claude Code, Cursor)

### Airflow (Production)
- **88 active pipelines** (as of Jan 2026)
- Runs from minutes to hours
- Andre is fluent in managing this system

---

## Key Insights

1. **Notion is a "dumping ground"** - only ~10% useful for extraction
2. **Important docs**: DevOps KT, Event Tracking, Engineering Expectations
3. **Development process** is in ClickUp, not Notion
4. **Data pipelines** use PRD templates in git repos now
5. **Team has contracted significantly** - documentation practices reduced

---

## Follow-up Items

- [ ] Extract SSH tunnel commands from Notion
- [ ] Document Amplitude event naming conventions
- [ ] Consider SSH key rotation (security)
- [ ] Archive outdated Notion content
