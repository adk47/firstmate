/*
id: lite_users_that_claimed_organizations
title: [Email] Lite Users that claimed organizations
athena_id: 2793367d-c29d-42bb-925f-9f1e63fcdcc1
primary_tag: email
tags: [email]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with ts as (
	select t.id as team_id,
		count_if(status = 'active') > 0 as is_active
	from "platform-core-backend-export-prod".public_teams as t
		left join "platform-core-backend-export-prod".public_subscriptions as s ON(t.id = s.teamid)
	group by 1
),
cl as (
	select t.id as team_id,
		c.profileid as profile_id,
		arbitrary(t.email) as email
	from "platform-core-backend-export-prod".public_claiming as c
		join "platform-core-backend-export-prod".public_teams as t ON (t.id = c.teamid)
	where status = 'processed' and profiletype = 'organization'
	group by 1,
		2
)
select distinct email
from cl
join ts USING(team_id)
where not coalesce(is_active, false)