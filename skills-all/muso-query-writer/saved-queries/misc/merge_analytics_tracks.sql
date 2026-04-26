/*
id: merge_analytics_tracks
title: [dev] Merge Analytics Tracks
athena_id: 749e7db9-a36c-4e5f-a66a-0ee55efa553d
primary_tag: dev
tags: [dev]
athena_database: platform-industry-bi-dev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with l AS (
	select distinct external_id AS spotify_id,
		track_id AS muso_track_id
	from "platform-industry-db-industry-prod".analytics_link
	where source = 'spotify'
),
a as (
	select track_id AS spotify_id,
		muso_track_id,
		max_by(streams, time_created) AS streams
	from "platform-analytics-export-prod".public_metrics_spotify_streams
		join l ON (track_id = spotify_id)
	group by 1,
		2
),
r AS (
	select muso_track_id,
		spotify_id,
		streams,
		nullif(release_date, '') AS release_date,
		title
	from hive.default.matvw_raw_recording AS r
		JOIN a ON ('spotify:' || spotify_id = r._id)
	where r.source = 'spotify'
		and nullif(isrc, '') is not null
		and streams > 10000
),
o AS (
	select muso_track_id,
		spotify_id,
		streams,
		release_date,
		title,
		max(streams) over (
			partition by muso_track_id
			ORDER BY streams desc RANGE streams * 0.01 preceding
		) as group_max_streams
	from r
),
p AS (
	select muso_track_id,
		first_value(spotify_id) over (
			partition by muso_track_id,
			group_max_streams
			order by coalesce(release_date, '2100-01-01'),
				length(title),
				spotify_id
		) AS main_id,
		spotify_id AS merge_id
	from o
),
g AS (
	select main_id,
		arbitrary(muso_track_id) AS muso_track_id,
		array_agg(distinct merge_id) AS merge_ids
	from p
	where p.main_id <> p.merge_id
		and p.merge_id not in (
			select distinct main_id
			from p
		)
	group by 1
	having count(distinct merge_id) > 1
)
SELECT 'merge_analytics_link' AS action_type,
	CAST(
		ROW('track', muso_track_id) AS ROW(entity_type VARCHAR, entity_id VARCHAR)
	) AS entity,
	CAST(
		ROW(
			'spotify:' || main_id,
			transform(merge_ids, t->'spotify:' || t),
			row('oleg', 'operations', 'adhoc_platform')
		) AS ROW(
			main_id VARCHAR,
			merge_ids ARRAY(VARCHAR),
			action_by row(id varchar, type varchar, sub_type varchar)
		)
	) AS data
from g
order by muso_track_id,
	main_id
limit 100