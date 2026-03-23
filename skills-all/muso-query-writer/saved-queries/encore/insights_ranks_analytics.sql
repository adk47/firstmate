/*
id: insights_ranks_analytics
title: [encore23] Insights Ranks Analytics
athena_id: 7b9c5abc-29db-47f3-a397-d6ba3395f17d
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
			from "platform-core-backend-export-prod"."public_profile_track_stats"
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
),
p AS (
	select pct
	from UNNEST(
			ARRAY_DISTINCT(
				sequence(1, 10, 1) || sequence(10, 50, 10) || sequence(50, 90, 5) || sequence(90, 99, 1) || array [ 99.9 ]
			)
		) AS p(pct)
)
select pct AS percentile,
	approx_percentile(streams, pct / 100) AS streams,
	approx_percentile(shazams, pct / 100) AS shazams,
	approx_percentile(videos, pct / 100) AS videos,
	approx_percentile(video_views, pct / 100) AS video_views,
	approx_percentile(streams_2023, pct / 100) AS streams_2023,
	approx_percentile(shazams_2023, pct / 100) AS shazams_2023,
	approx_percentile(videos_2023, pct / 100) AS videos_2023,
	approx_percentile(video_views_2023, pct / 100) AS video_views_2023
from s
	cross join p
group by 1
order by 1 desc