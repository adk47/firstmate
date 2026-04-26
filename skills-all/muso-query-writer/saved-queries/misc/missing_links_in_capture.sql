/*
id: missing_links_in_capture
title: [inhouse_analytics] Missing links in capture
athena_id: b5931fa1-a81e-45db-aa17-91d7fa9892b5
primary_tag: inhouse_analytics
tags: [inhouse_analytics]
athena_database: platform-industry-bi-dev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with _s AS (
	select distinct source_recording_id as external_id,
		SPLIT_PART(release_id, ':', 2) AS entity_id
	from hive.default.matvw_raw_recording
		cross join unnest(release_ids) AS r(release_id)
	where source = 'spotify'
),
ind as (
	select distinct source,
		IF(source = 'spotify', entity_id, external_id) AS entity_id,
		entity_type
	from hive.default.matvw_analytics_link AS l
		left join _s USING(external_id)
		left join (
			select 'youtube' AS source,
				'track' AS entity_type
			union all
			select 'youtube' AS source,
				'social' AS entity_type
			union all
			select 'soundcloud' AS source,
				'track' AS entity_type
			union all
			select 'shazam' AS source,
				'track' AS entity_type
			union all
			select 'spotify' AS source,
				'album' AS entity_type
			union all
			select 'tiktok' AS source,
				'social' AS entity_type
		) as y USING(source)
		where source <> 'instagram'
),
cap AS (
	select distinct source,
		entity_id,
		entity_type,
		TRUE as in_capture_db
	from "platform-analytics-export-prod".public_entities
)
select 
    source,
    entity_type,
    count(1)
from ind
	left join cap USING(source, entity_id, entity_type)
where in_capture_db is null
group by 1,2 
order by 3 desc