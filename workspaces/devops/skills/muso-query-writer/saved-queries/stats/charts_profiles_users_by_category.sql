/*
id: charts_profiles_users_by_category
title: [stats] Charts profiles users by category
athena_id: 04ca3b63-fd3c-40dd-8cae-3e84de58791f
primary_tag: stats
tags: [stats]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p as (
	select profile_id,
		TRUE AS is_user,
		bool_or(COALESCE(is_claimed, FALSE)) AS is_claimed,
		bool_or(COALESCE(is_pro, FALSE)) AS is_pro
	from (
			select seatid as profile_id,
				IF(status = 'active', TRUE, FALSE) AS is_pro,
				NULL as is_claimed
			from "production-musomvp".public_roster_seats
			union all
			select profileid as profile_id,
				NULL AS is_pro,
				TRUE as is_claimed
			from "production-musomvp".public_claiming
			where status = 'processed'
		)
	group by 1
),
ch AS (
	select profile_id,
		category,
		min(position) AS min_position
	from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
	where date in (
			select max(date)
			from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
		)
		and position <= 1000
	group by 1,
		2
)
select category,
	count_if(min_position <= 100) AS num_100,
	count_if(
		min_position <= 100
		and is_user
	) AS num_100_user,
	count_if(
		min_position <= 100
		and is_claimed
	) AS num_100_claimed,
	count_if(
		min_position <= 100
		and is_pro
	) AS num_100_pro,
	count_if(min_position <= 300) AS num_300,
	count_if(
		min_position <= 300
		and is_user
	) AS num_300_user,
	count_if(
		min_position <= 300
		and is_claimed
	) AS num_300_claimed,
	count_if(
		min_position <= 300
		and is_pro
	) AS num_300_pro,
	count_if(min_position <= 500) AS num_500,
	count_if(
		min_position <= 500
		and is_user
	) AS num_500_user,
	count_if(
		min_position <= 500
		and is_claimed
	) AS num_500_claimed,
	count_if(
		min_position <= 500
		and is_pro
	) AS num_500_pro
from ch
	left join p USING(profile_id)
group by 1
order by 1