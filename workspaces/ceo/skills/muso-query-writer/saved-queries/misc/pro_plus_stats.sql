/*
id: pro_plus_stats
title: PRO/PLUS stats
athena_id: 16946eb0-7319-438d-8dd3-1376ed74f0a5
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
		email,
		fullname AS name,
		subscriptionstatus AS subscription_status,
		NULLIF(COALESCE(appledata, googledata), '') is NULL AS is_boomer
	from "production-musomvp"."public_users"
),
usr_seats AS (
	select userid AS user_id,
		count(1) AS total_seats_num,
		count_if(
			status = 'active'
			AND deletedat is NULL
		) AS paid_seats_num,
		count_if(
			status = 'active'
			AND deletedat is NULL
			AND seatid is not null
		) AS occupied_seats_num,
		filter(
			ARRAY_AGG(
				DISTINCT IF(
					status = 'active'
					AND deletedat is NULL,
					seatid
				)
			),
			e->e IS NOT NULL
		) AS profile_ids
	from "production-musomvp"."public_discovery_seats"
	GROUP BY 1
),
prof_tracks AS (
	select profile_id,
		track_id,
		MAX(streams) AS streams
	from (
			SELECT profileid as profile_id,
				MAX_BY(
					SPLIT(substr(tracksids, 2, LENGTH(tracksids) -2), ','),
					date
				) as track_ids
			FROM "production-musomvp"."public_profile_analytics_stats_history"
			group by 1
		)
		CROSS JOIN UNNEST(track_ids) AS t(track_id)
		JOIN (
			select trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "production-musomvp"."public_track_stats"
			WHERE date between '2022-06-01' and '2022-07-01'
			group by 1
		) USING(track_id)
	group by 1,
		2
),
tracks AS (
	select user_id,
		count(distinct(track_id)) as num_tracks,
		SUM(streams) / 1000000.0 AS usr_streams
	FROM usr_seats AS s
		JOIN prof_tracks AS t ON (array_position(profile_ids, profile_id) > 0)
	group by 1
)
select IF(paid_seats_num > 1, 'PRO_PLUS', 'PRO') AS subscription,
	count(1) AS num_usrs,
	AVG(num_tracks) AS avg_tracks,
	AVG(occupied_seats_num) AS avg_seats_occupied,
	approx_percentile(occupied_seats_num, 0.5) AS p50_seats_occupied,
	approx_percentile(occupied_seats_num, 0.75) AS p75_seats_occupied,
	AVG(usr_streams) AS avg_mil_streams,
	approx_percentile(usr_streams, 0.5) AS p50_mil_streams,
	approx_percentile(usr_streams, 0.9) AS p90_mil_streams
from usr
	LEFT JOIN usr_seats USING(user_id)
	LEFT JOIN tracks USING(user_id)
where subscription_status = 'PRO'
	AND NOT is_boomer
group by 1