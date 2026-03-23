/*
id: ranks_distribution
title: [Industry] Ranks distribution
athena_id: 8287de4c-f5d0-41a8-aadb-eb59e551d789
primary_tag: industry
tags: [industry]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 'track',
	COALESCE(rank."$numberint", '5') AS rank,
	count(1)
from catalog_track
group by 1,
	2
union all
select 'album',
	COALESCE(rank."$numberint", '5') AS rank,
	count(distinct album_id)
from catalog_release
group by 1,
	2
union all
select IF(profile_type = 'artist', 'artist', 'professional'),
	COALESCE(rank."$numberint", '5') AS rank,
	count(1)
from catalog_profile
group by 1,
	2