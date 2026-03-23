/*
id: signup_claim_credits_pro
title: [reporting] SignUp -> Claim -> Credits -> PRO
athena_id: 9de65860-a97d-4cdb-a523-aeae625f864f
primary_tag: reporting
tags: [reporting]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with w AS (
	select id AS workspace_id,
		cast(createdat AS timestamp) AS signup_time
	from public_teams
	where cast(createdat AS timestamp) between date('2023-11-01') and date('2023-12-01')
		and isdefault
),
cl AS (
	select teamid AS workspace_id,
		MIN(cast(createdat AS timestamp)) AS claim_time
	from public_claiming
	where cast(createdat AS timestamp) between date('2023-11-01') and date('2023-12-07')
		and status = 'processed'
	group by 1
),
c AS (
	select workspaceid AS workspace_id,
		MIN(cast(createdat AS timestamp)) AS credit_time
	from public_credit_requests
	where cast(createdat AS timestamp) between date('2023-11-01') and date('2023-12-07')
		and status = 'approved'
	group by 1
),
a AS (
	select teamid AS workspace_id,
		MIN(cast(createdat AS timestamp)) AS active_time
	from public_roster_seats
	where cast(createdat AS timestamp) between date('2023-11-01') and date('2023-12-07')
		and status = 'active'
	group by 1
)
select date(signup_time) AS signup_date,
	count(1) AS num,
	count(claim_time) AS num_claim,
	count(credit_time) AS num_credit,
	count(active_time) AS num_pro,
	count_if(
		active_time is not null
		and claim_time is not null
	) AS num_claim_and_pro,
	count_if(
		active_time is not null
		and credit_time is not null
	) AS num_credit_and_pro
from w
	LEFT JOIN cl using(workspace_id)
	LEFT JOIN c using(workspace_id)
	LEFT JOIN a using(workspace_id)
group by 1
order by 2 desc