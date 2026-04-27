/*
id: label_smaller_groups
title: [org] Label smaller groups
athena_id: 51405a26-af1d-40ca-9e33-9fa2bff3bd9d
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
	from hive."platform-industry-bi-prod".matvw_raw_release
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
		min(from_unixtime(release_timestamp / 1000)) > date('2023-01-01') AS is_new,
		min(from_unixtime(release_timestamp / 1000)) > date('2022-01-01') AS is_last_2_years
	from hive."platform-industry-bi-prod".matvw_catalog_track AS t
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
		count_if(is_last_2_years) AS num_tracks_last_2_years,
		count_if(rank < 4) AS num_tracks_rank123,
		row_number() over (partition by count(1)) AS cnt_same_num_tracks,
		row_number() over (partition by count_if(rank < 4)) AS cnt_same_num_tracks_last_year
	from lt
	group by 1
	having count_if(is_last_2_years) > 0
)
select case
		when num_tracks > 100000 then 100000
		when num_tracks > 20000 then num_tracks/10000 * 10000
		when num_tracks > 1000 then num_tracks/1000 * 1000
		when num_tracks > 100 then num_tracks/100 * 100
		when num_tracks > 10 then num_tracks/10 * 10
		else num_tracks
	end AS group_min_tracks,
	count(1) AS num_labels,
	count_if(num_tracks_last_year > 0) AS num_labels_released_last_year,
	approx_percentile(num_tracks, 0.5) AS median_tracks,
	approx_percentile(num_tracks_last_year, 0.5) AS median_tracks_last_year,
	max(num_tracks) AS max_tracks,
	min(num_tracks) AS min_tracks,
	max(num_tracks_last_year) AS max_last_year_tracks,
	min(num_tracks_last_year) AS min_last_year_tracks,
	max_by(num_tracks, cnt_same_num_tracks) AS mode,
	max_by(num_tracks_last_year, cnt_same_num_tracks_last_year) AS mode_last_year
from l
group by 1
order by 1 desc