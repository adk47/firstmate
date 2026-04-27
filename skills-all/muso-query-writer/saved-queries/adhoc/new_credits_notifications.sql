/*
id: new_credits_notifications
title: [adhoc] New Credits notifications
athena_id: 1197cde2-9f9c-4d16-8847-a62e87392baa
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with up AS (
	select seatid as profile_id,
		teamid as workspace_id,
		userid as user_id,
		count(1) over (partition by teamid, seatid) > 1 as is_multi_user_workspace,
		BOOL_OR(u.email like '%@muso.ai' or u.email in ('aarondkaufman@gmail.com')) AS is_muso_user
	from postgresql_core.public.roster_seats
		join postgresql_core.public.team_users USING(teamid)
		join postgresql_core.public.users as u ON(userid = u.id)
-- 	where email not like '%@muso.ai'
	group by 1,
		2,
		3
),
a as (
	select user_id,
		date(
			from_unixtime(
				try_cast(
					c."added"."timestamp"."$date"."$numberLong" as bigint
				) / 1000
			)
		) AS added_date,
		count(distinct workspace_id || profile_id) AS num_notifs,
		bool_or(is_multi_user_workspace) as is_multi_user_workspace,
		bool_or(is_muso_user) as is_muso_user
	from hive."platform-industry-bi-prod".matvw_catalog_master_credit
		join up USING(profile_id)
		cross join unnest(catalog_credits) AS cc(c)
	where c."added"."by"."type" = 'raw'
	group by 1,
		2
),
u AS (
	select user_id,
		bool_or(is_multi_user_workspace) as is_multi_user_workspace,
		bool_or(is_muso_user) as is_muso_user,
		AVG(num_notifs) AS avg_n,
		MAX(num_notifs) AS max_n,
		1.0 * count(1) / 30 as days_pct
	from a
	where added_date > current_date - interval '31' day
	group by 1
)
select 
    is_muso_user,
    is_multi_user_workspace,
	CEIL(SUM(days_pct)) as num_users,
	AVG(avg_n) as avg_notifs,
	approx_percentile(max_n, 0.90) AS p90_notifs,
	approx_percentile(max_n, 0.99) AS p99_notifs,
	approx_percentile(max_n, 0.999) AS p999_notifs,
	max(max_n) AS max_notifs,
	max_by(user_id, max_n) AS max_notifs_user
from u
group by 1, 2
order by 3