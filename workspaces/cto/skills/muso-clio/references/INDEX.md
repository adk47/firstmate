# Muso.AI Knowledge (Deployed)

This folder is the **deployed knowledge surface** for the Mac mini Openclaw instance.

- **Deployment contract:** everything under `skills/` is rsynced to `~/clawd/skills/`
- **Single source of truth:** curated knowledge lives under `skills/muso-clio/references/`
- **Repo-only provenance:** raw exports and full meeting artifacts live outside `skills/` (e.g. `sources/`, `kt-recordings/`)

## Load Order (recommended)

1. `cheatsheet.md` (fast cross-system primer)
   - Maintainers: see `operations/knowledge-base-configuration.md` for how this repo deploys to Openclaw
2. `business/README.md` + `business/glossary.md` (terms, product context)
3. `architecture/README.md` (services, ownership, system map)
3. Domain-specific deep dives:
   - `core-backend/`
    - `web-credits/`
   - `mobile/`
   - `data-platform/`
   - `industry-data/`
   - `analytics-worker/`
   - `devops/`
4. `data-model/` (authoritative data model docs)
5. `operations/` (support workflows, Retool, operational runbooks)

## Domains

- `architecture/` — system overview + cross-cutting docs
- `business/` — product overview + glossary
- `data-model/` — schema vocabulary and source mapping
- `operations/` — operational procedures and internal tools
- `core-backend/`, `web-credits/`, `mobile/`, `data-platform/`, `industry-data/`, `analytics-worker/`, `devops/` — service-specific docs
