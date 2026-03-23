/*
id: popularity_distribution
title: [research] Popularity distribution
athena_id: a30dcb10-a199-49a8-b20d-0f0af75edc85
primary_tag: research
tags: [research]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 'profile' AS type,
	CEIL(coalesce("popularity", 0) / 10.0) * 10 AS bracket,
	count(1) AS num,
	1.0 * count(1) / sum(count(1)) over () AS pct
from "matvw_catalog_profile"
group by 1,
	2
union all
select 'release' AS type,
	CEIL(coalesce("popularity", 0) / 10.0) * 10 AS bracket,
	count(1) AS num,
	1.0 * count(1) / sum(count(1)) over () AS pct
from "matvw_catalog_release"
group by 1,
	2
union all
select 'track' AS type,
	CEIL(coalesce("popularity", 0) / 10.0) * 10 AS bracket,
	count(1) AS num,
	1.0 * count(1) / sum(count(1)) over () AS pct
from "matvw_catalog_track"
group by 1,
	2
order by 1,
	2 desc