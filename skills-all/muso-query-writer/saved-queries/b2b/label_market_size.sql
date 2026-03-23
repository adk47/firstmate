/*
id: label_market_size
title: [B2B] Label market size
athena_id: c082f4c2-d480-47cc-9b78-c5ba373f217c
primary_tag: b2b
tags: [b2b]
athena_database: platform-industry-mlc-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with lr AS (
	select custom_data.label AS label,
		rid
	from "platform-industry-bi-prod".matvw_raw_release
		cross join unnest(
			array_distinct(transform(recordings, r->r.recording_id))
		) AS r(rid)
	where _id like 'spotify:%'
),
lt as (
	select label,
		t._id AS track_id,
		min(coalesce(rank, 5)) as rank,
		max(coalesce(popularity, 0)) as popularity,
		min(from_unixtime(release_timestamp / 1000)) > date('2023-01-01') AS is_new
	from "platform-industry-bi-prod".matvw_catalog_track AS t
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
select 
    count(1) as num,
    count_if(num_tracks>0) as num_0,
    count_if(num_tracks>100) as num_100,
    count_if(num_tracks>1000) as num_1000,
    count_if(num_tracks>10000) as num_10000
from l