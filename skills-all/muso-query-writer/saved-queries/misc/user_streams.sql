/*
id: user_streams
title: User Streams
athena_id: 07549711-7c03-43bf-a9be-0615cff23c5a
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select id AS user_id,
		neptuneprofessionalid AS profile_id,
		email,
		fullname AS name,
		subscriptionstatus AS subscription_status,
		createdat AS created_at
	from "production-musomvp"."public_users"
),
prof_streams AS (
	select profile_id,
		SUM(streams) AS streams
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
		)
		CROSS JOIN UNNEST(track_ids) AS t(track_id)
		JOIN (
			select 
			    profileid AS profile_id,
			    trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "production-musomvp"."public_profile_track_stats" 
			group by 1, 2
		) USING(profile_id, track_id)
	group by 1
)
select user_id,
	profile_id,
	email,
	name,
	subscription_status,
	created_at,
	streams
from usr
	LEFT JOIN prof_streams USING(profile_id)
	where subscription_status is not NULL
order by 1