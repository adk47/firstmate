/*
id: teams_with_5_active_seats_profiles
title: [Encore25] Teams with 5+ active seats (profiles)
athena_id: f02dfb92-c768-41ff-8585-bb3e87e3b605
primary_tag: encore
tags: [encore]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with ts as (
    select 
        *
    from (
    select 
        teamid,
        count(distinct seatid) as num_seats,
        count(distinct IF(status='active', seatid)) as num_active_seats
    from postgresql_core.public.roster_seats 
    group by 1
    )
    where num_active_seats > 4
), 
tu as (
    select
        u.email,
        max_by(t.name, row(num_active_seats, num_seats, teamid)) as team_name,
        max(num_active_seats) as num_active_seats,
        'https://musoai.retool.com/apps/c0f441da-6e5c-11ee-bc6e-07ffdf65af60/Growth/Workspace%20Details?workspaceId=' || max_by(teamid, row(num_active_seats, num_seats, teamid)) as team_url
	from postgresql_core.public.team_users as tu
		join ts USING(teamid)
		join postgresql_core.public.teams as t ON(teamid=t.id)
		join postgresql_core.public.users as u ON (tu.userid = u.id)
	where roles like '%owner%' and u.email not like '%muso.ai%'
	group by 1
)
select * 
from tu
order by num_active_seats desc