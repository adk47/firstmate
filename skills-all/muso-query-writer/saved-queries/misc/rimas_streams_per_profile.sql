/*
id: rimas_streams_per_profile
title: [teams] Rimas Streams per profile
athena_id: 92302c44-95d2-4588-9393-de149b2ebc69
primary_tag: teams
tags: [teams]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select _id AS profile_id,
		name,
		ARRAY_JOIN(common_credits, ', ') AS common_credits
	from hive.default.matvw_catalog_profile AS p
		join "production-musomvp".public_roster_seats AS s ON(p._id = s.seatid)
	where s.status = 'active'
		and s.teamid = 'aa9fcc0f-516f-487d-8456-c90111891681'
),
prof_streams AS (
	select profile_id,
		SUM(total_streams) AS total_streams,
		SUM(spotify) AS spotify,
		SUM(soundcloud) AS soundcloud,
		SUM(youtube) AS youtube,
		SUM(total_social_views) AS total_social_views,
		SUM(tiktok_views) AS tiktok_views,
		SUM(instagram_reels) AS instagram_reels,
		SUM(youtube_shorts) AS youtube_shorts
	from (
			SELECT profileid as profile_id,
				MAX_BY(
					SPLIT(substr(tracksids, 2, LENGTH(tracksids) -2), ','),
					date
				) as track_ids
			FROM "production-musomvp"."public_profile_analytics_stats_history"
			WHERE profileid IN (
					select profile_id
					from usr
				)
			group by 1
			having date_diff(
					'day',
					DATE(SUBSTR(max(date), 1, 10)),
					current_date
				) <= 2
		)
		CROSS JOIN UNNEST(track_ids) AS t(track_id)
		JOIN (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS total_streams,
				sum(COALESCE(spotifystreams, 0)) AS spotify,
				sum(COALESCE(soundcloudstreams, 0)) AS soundcloud,
				sum(COALESCE(youtubeviews, 0)) AS youtube,
				
				SUM(
					COALESCE("tiktokviews", 0) + COALESCE("instagramviews",  0) + COALESCE("youtubeshortsviews",  0)
				) AS total_social_views,
				sum(COALESCE(tiktokviews, 0)) AS tiktok_views,
				sum(COALESCE(instagramviews, 0)) AS instagram_reels,
				sum(COALESCE(youtubeshortsviews, 0)) AS youtube_shorts
			from "production-musomvp"."public_profile_track_stats"
			group by 1,
				2
		) USING(profile_id, track_id)
	group by 1
)
select *
from usr
	JOIN prof_streams USING(profile_id)
order by total_streams desc