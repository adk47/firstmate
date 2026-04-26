/*
id: artist_member_affected_credits
title: [adhoc] Artist Member affected credits
athena_id: 06085358-fdbd-48d0-ab4a-fa7ede26835a
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p as (
	select distinct seatid as profileid
	from "production-musomvp".public_roster_seats
	where status = 'active'
),
ts AS (
	select track_id AS master_track_id,
		MAX(streams) AS streams
	from (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "production-musomvp"."public_profile_track_stats"
			join p using (profileid)
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
from (
		select profile_id,
			count(1) AS tracks,
			count_if(affected_streams > 0) AS affected_tracks,
			SUM(streams) AS total_streams,
			SUM(affected_streams) AS affected_streams
		from (
				select profile_id,
					master_track_id as track_id,
					streams,
					IF(
						cardinality(
							filter(catalog_credits, c->c.child = 'Artist Member')
						) > 0
						and cardinality(
							filter(catalog_credits, c->c.child <> 'Artist Member')
						) = 0,
						streams,
						0
					) AS affected_streams
				from hive.default.matvw_catalog_master_credit
					join ts USING(master_track_id)
			)
		group by 1
	)
where affected_tracks > 0
order by 1.0 * affected_streams / total_streams desc