/*
id: subscription_rate
title: [reporting] Subscription rate
athena_id: ce559e5e-bf26-4274-9d9a-9a435b31efcd
primary_tag: reporting
tags: [reporting]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with u AS (
	select id as team_id,
		date(
			cast(createdat as timestamp) - interval '8' hour
		) AS date
	from public_teams
),
s as (
	select sub_date as date,
		count(1) AS num_sub,
		count_if(date_diff('day', u.date, sub_date) < 8) AS num_conv_sub,
		count_if(plan like '%annual%') AS num_trial,
		count_if(
			date_diff('day', u.date, sub_date) < 8
			and plan like '%annual%'
		) AS num_conv_trial
	from (
			select teamid AS team_id,
				MAX(
					date(
						cast(createdat as timestamp) - interval '8' hour
					)
				) AS sub_date,
				MAX_BY(plan, createdat) AS plan
			from public_subscriptions
			group by 1
		) AS s
		join u USING(team_id)
	group by 1
)
select date,
	num_users,
	num_sub,
	num_trial,
	100.0 * num_sub / num_users AS subscription_per_registered_pct,
	100.0 * num_conv_sub / num_users AS subscription_8d_reg_pct,
	100.0 * num_conv_sub / num_sub AS subscribed_d_after_registration_pct
from (
		select date,
			count(1) as num_users
		from u
		group by 1
	) AS u
	left join s USING(date)
where date > date('2023-11-01')