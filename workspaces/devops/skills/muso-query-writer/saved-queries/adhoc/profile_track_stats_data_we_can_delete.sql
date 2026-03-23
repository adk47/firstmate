/*
id: profile_track_stats_data_we_can_delete
title: [adhoc] profile_track_stats data we can delete
athena_id: c60c3623-0f3d-43c0-8140-8886e1eb4a1c
primary_tag: adhoc
tags: [adhoc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p as (
	select distinct seatid as profileid,
		TRUE AS is_pro
	from "production-musomvp".public_roster_seats
	where status = 'active'
),
a AS (
	select profileid,
		count(1) AS num_rows
	from "production-musomvp".public_profile_track_stats
	group by 1
)
select is_pro,
	sum(num_rows) AS num_rows
from a
	left join p USING(profileid)
group by 1