/*
id: stale_streams_profiles
title: [analytics] Stale streams profiles
athena_id: 7e68cfe9-455d-415a-9c08-cf9166f95a45
primary_tag: analytics
tags: [analytics]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro_profiles AS (
	select distinct seatid
	FROM "production-musomvp"."public_roster_seats"
	WHERE status = 'active'
)
select profileid,
	count(1) AS num_tracks,
	count_if(
		is_stale
		and streams > 0
	) AS num_stale,
	SUM(streams) AS total_streams,
	SUM(IF(is_stale, streams)) AS stale_tracks_streams
from (
		select profileid,
			trackid,
			SUM(streams) AS streams,
			SUM(
				IF(
					date_diff('week', Date("date"), current_date) <= 2,
					streams
				)
			) = 0 AS is_stale
		from (
				select profileid,
					trackid,
					date,
					max(
						COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
					) as streams
				from "production-musomvp"."public_profile_track_stats"
					join pro_profiles on profileid = seatid
				group by 1,
					2,
					3
			)
		group by 1,
			2
	)
group by 1
order by 3 desc