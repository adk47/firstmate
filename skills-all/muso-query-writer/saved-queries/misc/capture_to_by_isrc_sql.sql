/*
id: capture_to_by_isrc_sql
title: [songstats] Capture to by ISRC SQL
athena_id: 9e6e7dbc-7e85-4354-b5a7-b2dd389b821c
primary_tag: songstats
tags: [songstats]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 'track' AS entity,
	isrc as id
from (
		select isrc,
			MAX(COALESCE(custom_data.popularity, 0)) AS popularity,
			MIN(release_date) AS release_date,
			min(title) AS title
		from hive."platform-industry-bi-prod".matvw_raw_recording
		where not is_deleted
			and split_part(_id, ':', 1) = 'spotify'
			and nullif(isrc, '') is not null 
		group by 1
	)
order by popularity desc,
	release_date desc,
	isrc
limit 10