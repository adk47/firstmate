/*
id: label_groups_be_tracks_size
title: [org] Label groups be tracks size
athena_id: 2cd4b938-4068-4b3a-9bf2-30f3a346d23d
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
),
lt as (
	select label,
		t._id AS track_id,
		min(coalesce(rank, 5)) as rank,
		max(coalesce(popularity, 0)) as popularity,
		min(from_unixtime(release_timestamp / 1000)) > date('2023-01-01') AS is_new
	from hive.default.matvw_catalog_track AS t
		cross join unnest(raw_recording_ids) AS r(rid)
		join lr USING(rid)
	where not t.is_deleted
	group by 1,
		2
),
l as (
	select label,
		count(1) AS num_tracks,
		count_if(is_new) AS num_tracks_last_year,
		count_if(rank < 4) AS num_tracks_rank123
	from lt
	group by 1
)
select case
		when num_tracks > 100000 then 100000
		when num_tracks > 20000 then 20000
		when num_tracks > 1000 then 1000
		when num_tracks > 100 then 100
		when num_tracks > 10 then 10
		when num_tracks > 1 then 2 else 1
	end AS group_min_tracks,
	count(1) AS num_labels,
	count_if(num_tracks_last_year > 0) AS num_labels_released_last_year,
	approx_percentile(num_tracks, 0.5) AS median_tracks,
	approx_percentile(num_tracks_last_year, 0.5) AS median_tracks_last_year,
	max(num_tracks) AS max_tracks,
	min(num_tracks) AS min_tracks,
	max(num_tracks_last_year) AS max_last_year_tracks,
	min(num_tracks_last_year) AS min_last_year_tracks
from l
group by 1
order by 1 desc