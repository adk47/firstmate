/*
id: email_segments
title: [Marketing] Email segments
athena_id: 0f44753c-ff2d-4a24-ab00-1b9bd540ce1d
primary_tag: marketing
tags: [marketing]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with wu as (
	select t.id as workspace_id,
		arbitrary(t.email) as workspace_email,
		max_by(s.status, s.updatedat) as status,
		max_by(plan, s.updatedat) as plan
	from "platform-core-backend-export-prod".public_teams as t
		left join "platform-core-backend-export-prod".public_subscriptions as s ON (t.id = s.teamid)
	group by 1
),
wuu as (
	select workspace_id,
		email,
		count_if(status = 'active') > 0 as is_active
	from wu
		join "platform-core-backend-export-prod".public_team_users as tu ON (workspace_id = teamid)
		join "platform-core-backend-export-prod".public_users as u ON (tu.userid = u.id)
	where visible
		and nullif(email, '') is not null
		and status in ('active', 'cancelled') -- 		and roles like '%owner%'
	group by 1,
		2
),
wcl as (
	select teamid as workspace_id,
		count_if(
			status = 'processed'
			and coalesce(profiletype, 'artist') = 'organization'
		) > 0 as is_company_claimed,
		count_if(
			status = 'processed'
			and coalesce(profiletype, 'artist') <> 'organization'
		) > 0 as is_profile_claimed
	from "platform-core-backend-export-prod".public_claiming as c
	group by 1
)
select email,
	IF(
		BOOL_OR(coalesce(is_active, false)),
		'active',
		'cancelled'
	) as status,
	case
		when BOOL_OR(COALESCE(is_company_claimed, FALSE)) then 'B2B'
		when BOOL_OR(COALESCE(is_profile_claimed, FALSE)) then 'B2C - claimed' else 'B2C - view'
	end as category
from wuu
	left join wcl USING(workspace_id)
group by 1