/*
id: streams_percent
title: Streams Percent
athena_id: ca66f5c8-98f6-44d9-824f-a2caa642bacc
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro AS (
	select neptuneprofessionalid AS profileId
	from "production-musomvp"."public_users"
	where subscriptionstatus = 'PRO'
),
profile_tracks AS (
	select profileid,
		trackid
	from (
			select profileId,
				split(
					replace(
						replace(MAX_BY(tracksids, date), '{', ''),
						'}',
						''
					),
					','
				) AS track_ids
			from "production-musomvp"."public_profile_analytics_stats_history"
				join pro using(profileId)
			group by 1
		)
		cross join unnest(track_ids) AS t(trackid)
),
track_stats as (
	SELECT trackid,
		SUM(spotifystreams) + SUM(soundcloudstreams) + SUM(youtubeviews) AS sum_streams
	FROM "production-musomvp".public_track_stats
	GROUP BY 1
),
top_cum_streams AS (
	select 100 * top_track_num / num_tracks AS top_num_pct,
		100 * cumulative_streams / total_streams AS top_streams_pct,
		count(1)
	from (
			select profileid,
				trackid,
				COUNT() OVER (partition by profileid) AS num_tracks,
				row_number() OVER (
					partition by profileid
					ORDER BY sum_streams DESC
				) AS top_track_num,
				sum_streams AS track_streams,
				SUM(sum_streams) OVER(partition by profileid) AS total_streams,
				SUM(sum_streams) OVER(
					partition by profileid
					ORDER BY sum_streams DESC
				) AS cumulative_streams
			from profile_tracks
				LEFT JOIN track_stats USING(trackid)
		)
	group by 1,
		2
)
select top_num_pct,
	AVG(top_streams_pct) AS avg_streams_pct
from top_cum_streams
group by 1
order by 1