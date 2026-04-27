/*
id: sync_tracks
title: [OKR] Sync % (tracks)
athena_id: 1a61be29-91e2-4adf-bf9b-66b19f5748ad
primary_tag: okr
tags: [okr]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with r as (
	select _id
	from hive."platform-industry-bi-prod"."matvw_raw_recording"
	where not coalesce(is_deleted, false)
),
c as (
	select raw_id
	from hive."platform-industry-bi-prod"."matvw_catalog_track"
		cross join unnest(raw_recording_ids) as t(raw_id)
),
counts as (
	select split_part(r._id, ':', 1) AS source,
		count(1) as num_raw,
		count(c.raw_id) as num_synced
	from r
		left join c on c.raw_id = r._id
	group by 1
)
select source,
	num_raw,
	num_synced,
	100.0 * num_synced / num_raw as percentage,
	100.0 * SUM(num_synced) OVER () / SUM(num_raw) OVER () AS total_percent
from counts
order by 2 desc