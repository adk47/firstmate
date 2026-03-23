# Architecture References

High-level system architecture and service documentation for Muso.AI.

## Available Documents

| File | Purpose |
|------|---------|
| `services-overview.md` | Teams, service ownership, AWS infrastructure, service interaction diagrams |
| `overview.md` | High-level system overview + document map |
| `database.md` | Cross-system database overview |
| `security.md` | Cross-system authentication/authorization overview |
| `integrations.md` | External services and integrations overview |
| `api_reference.md` | Cross-system API surfaces and auth flows |

## When to Load

Load these references when:
- Understanding the overall system architecture
- Identifying which team owns a service
- Finding AWS console links for clusters
- Understanding how services communicate
- Onboarding new engineers

## Source of Truth

These documents are derived from the [Oleg Knowledge Transfer Notion page](https://www.notion.so/High-Level-Document-2ed0aeed21ad80a28eedffdc9fcb1f96).

## Related References

- `devops/` - Infrastructure, Terraform, CI/CD details
- `core-backend/` - Core Backend API specifics
- `industry-data/` - Industry Processing details
- `analytics-worker/` - Capture Worker details
- `data-platform/` - MWAA/Airflow pipeline details
