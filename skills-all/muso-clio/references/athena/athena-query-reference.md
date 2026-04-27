# AWS Athena Query Reference (RETIRED)

> **MOVED — see [`../trino/trino-query-reference.md`](../trino/trino-query-reference.md)**
>
> AWS Athena was retired on **2026-04-25** as part of the AWS → OVH cutover.
> All historical materialized views, audit tables, and BI data now live in
> Trino on OVH (HMS + Hive on OVH S3 IO, plus PostgreSQL connectors for live PG).
>
> SQL syntax is largely unchanged (Trino is the engine Athena v3 was built on).
> The main differences are catalog/schema names and how queries are executed.
>
> Use `bash /opt/hydra/scripts/trino-query.sh "<SQL>"` from node-8 — it
> auto-rewrites the legacy `hive."platform-industry-bi-prod"` style DB names to
> their Trino equivalents, so old saved queries keep working.
>
> **Mapping table** (also in trino-query-reference.md):
>
> | Old Athena DB | New Trino reference |
> |---------------|---------------------|
> | `hive."platform-industry-bi-prod"` | `hive."platform-industry-bi-prod"` |
> | `postgresql_core.public` | `postgresql_core.public` |
> | `hive.audit` | `hive.audit` |
> | `bi` | `postgresql_analytics.public` |
> | `hive.mlc` | `hive.mlc` |
