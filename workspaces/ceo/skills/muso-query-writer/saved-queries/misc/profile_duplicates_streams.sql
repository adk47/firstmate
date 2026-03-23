/*
id: profile_duplicates_streams
title: Profile Duplicates Streams
athena_id: 6c402b00-81a0-45d7-bdac-c5f57a41ddf9
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with user_profiles AS (
	select neptuneprofessionalid AS profileid,
		fullname,
		email
	from "production-musomvp"."public_users"
	where "subscriptionstatus" = 'PRO'
),
track_stats AS (
	select trackid,
		sum(spotifystreams) AS streams
	from "production-musomvp"."public_track_stats"
	where spotifystreams > 0
	group by 1
),
track_profiles AS (
	select profileid,
		trackid,
		streams,
		LAG(streams) OVER (
			PARTITION BY profileid
			ORDER BY streams,
				trackid ASC
		) AS prev_streams
	from (
			select profileid,
				MAX_BY(tracksids, "date") AS tracksids
			from "production-musomvp"."public_profile_analytics_stats_history"
			WHERE "tracksids" is not null
				and profileid IN (
					select profileid
					from user_profiles
				)
			group by 1
		)
		CROSS JOIN UNNEST(split(TRIM(tracksids, '{}'), ',')) as t(trackid)
		JOIN track_stats USING(trackid)
),
profile_stats AS (
	select profileid,
		count(1) AS num_tracks,
		COUNT_IF(streams = prev_streams) AS num_dups,
		sum(streams) AS streams,
		SUM(IF(streams = prev_streams, streams, 0)) AS sum_dup_streams
	from track_profiles
	group by 1
)
select *
from user_profiles
	JOIN profile_stats USING(profileid)
	where sum_dup_streams > 0
order by streams desc