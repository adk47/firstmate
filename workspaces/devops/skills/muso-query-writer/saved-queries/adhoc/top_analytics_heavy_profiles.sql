/*
id: top_analytics_heavy_profiles
title: [AdHoc] Top analytics heavy profiles
athena_id: 5539ff65-d666-4547-abef-9ccfa18ec2cd
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with st AS (
	select profileid AS profile_id,
		count(1) as num_rows,
		count(distinct trackid) as num_tracks
	from "platform-core-backend-export-prod".public_profile_track_stats
	group by 1
),
ac AS (
	select distinct seatid AS profile_id,
		TRUE as is_active
	from "platform-core-backend-export-prod".public_roster_seats
	where status = 'active'
)
select *
from st
	join ac USING(profile_id)
order by num_tracks desc
limit 100