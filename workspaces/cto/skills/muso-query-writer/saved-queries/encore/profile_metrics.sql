/*
id: profile_metrics
title: [encore23] Profile metrics
athena_id: e0511330-1615-4f0b-92c3-3ae5ce08595c
primary_tag: encore
tags: [encore]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with t AS (
	select _id AS track_id,
		year(from_unixtime(release_timestamp / 1000)) AS release_year
	from "platform-industry-bi-prod".matvw_catalog_track
),
s AS (
	select profile_id,
		SUM(streams) AS streams,
		SUM(IF(release_year = 2023, streams, 0)) AS streams_2023,
		SUM(shazams) AS shazams,
		SUM(IF(release_year = 2023, shazams, 0)) AS shazams_2023,
		SUM(videos) AS videos,
		SUM(IF(release_year = 2023, videos, 0)) AS videos_2023,
		SUM(video_views) AS video_views,
		SUM(IF(release_year = 2023, video_views, 0)) AS video_views_2023
	from (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams,
				SUM(COALESCE(shazams, 0)) AS shazams,
				SUM(
					COALESCE(tiktokvideoscount, 0) + COALESCE(youtubeshortscount, 0) + COALESCE(instagramvideoscount, 0)
				) AS videos,
				SUM(
					COALESCE(tiktokviews, 0) + COALESCE(youtubeshortsviews, 0) + COALESCE(instagramviews, 0)
				) AS video_views
			from "production-musomvp"."public_profile_track_stats"
			group by 1,
				2
			having date_diff(
					'day',
					DATE(SUBSTR(max(date), 1, 10)),
					current_date
				) <= 2
		)
		join t USING(track_id)
	group by 1
)
select p.name,
	p.popularity,
	array_join(p.common_credits, ', ') AS common_credits,
	s.*
from s
	join "platform-industry-bi-prod".matvw_catalog_profile AS p ON (p._id = profile_id)
where not p.is_deleted
order by streams desc