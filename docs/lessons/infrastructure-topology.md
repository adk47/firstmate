# Infrastructure topology (what we actually run, and what's dead)

Three facts agents keep getting wrong. Ground every infra decision in these, and
check the canonical source (rule 3) before touching anything.

## 1. We run entirely on OVH -- AWS is decommissioned

Everything runs on **OVH**: the K3s cluster (namespace `muso-prod`; Cilium +
Longhorn + Vault + KEDA) plus bare-metal Postgres and Mongo. Databases are **OVH
Postgres** (Crunchy **PGO** PostgresClusters in the `databases` namespace --
`muso-core`, `muso-stats-pg`, `muso-olap-pg`, `muso-analytics-pg`, `muso-ic-pg`,
...) plus a bare-metal PG17 primary; the stats/OLAP backbone is `muso-stats-pg` /
`muso-olap-pg` on OVH, queried via Trino. hydra itself runs on OVH node-8.

**AWS was decommissioned on 2026-05-31** (CEO directive; the durable record is
`H-DevOps:docs/runbooks/aws-decommission-2026-05-31.md`). EKS, MWAA, ECS, RDS,
Aurora (`platform-stats-prod`), and ElastiCache were all torn down (~$93K/mo ->
~$0 recurring). **There is no Aurora, no RDS, no EKS -- do not reach for them,
they no longer exist.** The only AWS that remains is DNS (Route53 zone `muso.ai`,
RED-tier), a couple of S3 buckets for backups (pgBackRest / node-8 snapshots), and
the `help.muso.ai` CloudFront.

Watch out for **leftover AWS code in the IaC** (e.g. `aurora_scaling.py` in the
Airflow bundle, being patched out by `scripts/ovh-patches/aurora_scaling_ovh.py`).
Vestigial AWS references are NOT evidence AWS is live -- confirm against the
decommission runbook and the live OVH service manifests. Full spec:
`docs/reference/ARCHITECTURE.md` and `H-DevOps:docs/server-map.md`.

## 2. "v3" triage: frozen tables are DEAD, the V3 pipeline is SUNSETTING, `/api/v3` is the keeper

Three different things share the "v3" name:

- **Dead now**: the two frozen legacy stats tables `profile_v3_lifetime` and
  `profile_v3_tracks` ("v3 lifetime stats", frozen 2026-06-06). Do not read or build
  on them (see `docs/lessons/muso-domain.md`,
  `skills-all/muso-query-writer/trino-schemas.md`). **Athena is also gone** (retired
  2026-04-25) -- all analytics queries run through **OVH Trino** now.
- **Sunsetting -- do not build NEW dependencies on it** (CTO direction, 2026-07-24):
  the **V3 data-processing pipeline** (the V3 Airflow DAGs, the BI export behind
  `matvw_*` in `platform-industry-bi-prod`, the V3 PDP tier). It still SERVES
  production today -- many query-writer saved queries, dedup sweeps, and fraud
  lookups read `matvw_*`, so it is not switch-off-able yet and real breakage in it
  still matters -- but everything is migrating OFF it: ops merge verification
  already moved to the live-catalog admin read (PR #717), and core-backend readers
  are cutting over to the `cube_analytics_*` views (the #9204/#9208 sweep). New
  operational checks must use live sources (admin API / cube views), never the BI
  matviews, whose watermark can lag days.
- **Current and sanctioned -- the only "v3" to keep using**: the **`/api/v3`,
  `/api/w/v3`, `/api/m/v3`** REST routes (admin / web / mobile live Muso API).

## 3. Consult H-DevOps before touching infra

`Muso-AI/H-DevOps` is the canonical infrastructure-as-code repo -- k8s manifests
(`k8s/`, `helm/`), `terraform/`, `ansible/`, `scripts/`, `runbooks/`,
`docs/server-map.md`, `workers/`. It is authoritative over anything in hydra: this
file and `docs/reference/ARCHITECTURE.md` can drift; H-DevOps is the source of
truth (it is also where the decommission record and the live node/server map live).

It is a **private** repo -- not reachable via `gh` from a dev laptop (a
`nsollazzo` token 404s it); it lives as a checkout on node-8 at
`/opt/hydra/workspaces/repos/H-DevOps` (default branch `main`). That shared
checkout is often left on a feature branch by other agents, so read the
authoritative state from `origin/main` rather than the working tree:

```bash
git -C /opt/hydra/workspaces/repos/H-DevOps fetch origin
git -C /opt/hydra/workspaces/repos/H-DevOps show origin/main:k8s/...   # read a manifest
git -C /opt/hydra/workspaces/repos/H-DevOps show origin/main:docs/server-map.md
```

Before proposing, reviewing, or making ANY infra change, get current from
`origin/main` and read the relevant manifests/runbooks first. Agents may draft PRs
to H-DevOps but never merge -- a human merges.
