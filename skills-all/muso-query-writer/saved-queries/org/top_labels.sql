/*
id: top_labels
title: [org] Top Labels
athena_id: 4dc3077f-c8b7-49de-b808-b513e7174924
primary_tag: org
tags: [org]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with lr AS (
	select custom_data.label AS label,
		rid
	from hive.default.matvw_raw_release
		cross join unnest(
			array_distinct(transform(recordings, r->r.recording_id))
		) AS r(rid)
	where source = 'spotify'
)
select label,
	count(1) AS num_tracks,
	count_if(rank < 4) AS num_tracks_rank123,
	approx_percentile(popularity, 0.99) AS popularity_p99,
	approx_percentile(popularity, 0.9) AS popularity_p90,
	avg(popularity) AS popularity_average
from hive.default.matvw_catalog_track AS t
	cross join unnest(raw_recording_ids) AS r(rid)
	join lr USING(rid)
where not t.is_deleted
group by 1
order by 2 desc
limit 10000