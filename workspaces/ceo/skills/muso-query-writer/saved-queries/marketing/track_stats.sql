/*
id: track_stats
title: [marketing] Track Stats
athena_id: ba6a3304-ba8f-4be7-a49b-b5aed674bd45
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with t AS (
	select _id AS track_id,
		title,
		ARRAY_JOIN(transform(artists, a->a.name), ', ') AS artists,
		popularity
	from "platform-industry-bi-prod".matvw_catalog_track
),
ts AS (
	select track_id,
		MAX(streams) AS streams
	from (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "production-musomvp"."public_profile_track_stats"
			group by 1,
				2
			having date_diff(
					'day',
					DATE(SUBSTR(max(date), 1, 10)),
					current_date
				) <= 2
		)
	group by 1
)
select *
from t
	JOIN ts USING(track_id)
order by streams desc
limit 10000