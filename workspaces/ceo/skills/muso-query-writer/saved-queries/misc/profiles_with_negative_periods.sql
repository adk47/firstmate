/*
id: profiles_with_negative_periods
title: Profiles with negative periods
athena_id: d2ff0988-94a1-4104-b200-b5128b9b552a
primary_tag: misc
tags: [misc]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro as (
	select distinct seatid as profile_id
	from "platform-core-backend-export-prod".public_roster_seats as s
		join "platform-core-backend-export-prod".public_teams as t ON (t.id = s.teamid)
	where s.status = 'active'
		and t.inhouseanalyticsenabled
)
select 
	period,
	count(1) as num_profiles,
	count_if(ce_streams < 0) as num_affected
from "platform-industry-calc-prod".calc_analytics_cube_profile_history
join pro using(profile_id)
where
    date = '2024-05-01'
    and period in ('1m', '1w', '3m', '1y', 'ytd')
group by 1