/*
id: songstats_vs_inhouse_profiles
title: [analytics] SongStats vs InHouse profiles
athena_id: 4a2362b3-41b5-4ddc-ac39-b52012482304
primary_tag: analytics
tags: [analytics]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro as (
	select distinct seatid as profileid
	from postgresql_core.public.public_roster_seats as s
		join postgresql_core.public.public_teams as t ON (t.id = s.teamid)
	where s.status = 'active'
		and not t.inhouseanalyticsenabled
),
old AS (
    select 
        profile_id,
        sum(old_streams) as old_streams
    from (
    	select profileid AS profile_id,
    		trackid as track_id,
    		SUM(
    			COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
    		) AS old_streams
    	from postgresql_core.public."public_profile_track_stats"
    		join pro USING(profileid)
    	group by 1,
    		2
    	having date_diff(
    			'day',
    			DATE(SUBSTR(max(date), 1, 10)),
    			current_date
    		) <= 2
		)
		group by 1
),
new as (
	select profile_id,
		date,
		ce_streams as new_streams
	from "platform-industry-calc-prod".calc_analytics_cube_profile_history
	where date = cast(date_add('day', -1, current_date) as varchar)
		and period = 'all'
)
select profile_id,
	name,
	new_streams,
	old_streams,
	new_streams - old_streams AS diff,
	ABS(new_streams - old_streams) AS abs_diff,
	100 * ABS(new_streams - old_streams) / old_streams AS diff_pct
from (
		select profile_id,
			new_streams,
			old_streams
		from new
			join old USING(profile_id)
	) AS s
	join hive.default.matvw_catalog_profile AS p ON (p._id = profile_id)
where old_streams > 0
order by abs_diff desc