/*
id: suspended_and_cancel_analysis
title: [AdHoc] Suspended and Cancel analysis
athena_id: 96dce563-0b7c-4862-b10c-52e0c8c77d8c
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with ss as (
	select teamid,
		count_if(
			status = 'active'
			and json_extract_scalar(details, '$.autoRenew') = 'false'
		) > 0 as is_suspended,
		count_if(
			status = 'cancelled'
		) > 0 as is_cancelled,
		count_if(
			status = 'active'
			and coalesce(json_extract_scalar(details, '$.autoRenew'), '') <> 'false'
		) > 0 as is_active
	from "platform-core-backend-export-prod"."public_subscriptions"
	group by 1
	
-- 	select status, count(1) from "platform-core-backend-export-prod"."public_subscriptions" group by 1
),
cl as (
	select distinct profileid as profile_id,
		TRUE as is_claimed,
		teamid
	from "platform-core-backend-export-prod".public_claiming
	where status = 'processed'
),
r as (
	select distinct seatid as profile_id,
		status = 'active' as is_active_seat,
		teamid
	from "platform-core-backend-export-prod".public_roster_seats
),
tp as (
	select teamid,
		coalesce(r.profile_id, cl.profile_id) as profile_id,
		BOOL_OR(coalesce(is_suspended, FALSE) and NOT coalesce(is_active, FALSE)) as is_suspended,
		BOOL_OR(coalesce(is_cancelled, FALSE) and NOT coalesce(is_active, FALSE)) as is_cancelled,
		BOOL_OR(coalesce(is_claimed, FALSE)) as is_claimed,
		BOOL_OR(coalesce(is_active, FALSE)) as is_active,
		BOOL_OR(coalesce(is_active_seat, FALSE)) as is_active_seat
	from ss
		left join cl USING(teamid)
		left join r USING(teamid)
	group by 1,
		2
),
ps as (
	select profile_id,
		max(
			try(
				cast(
					reverse(
						split_part(reverse(replace(stream_stats, ']', '')), ',', 1)
					) as bigint
				)
			)
		) as streams
	from "platform-industry-calc-prod".calc_analytics_industry_stat_cube_profile_history
		join (
			select max(date) as date
			from "platform-industry-calc-prod"."calc_analytics_industry_stat_cube_profile_history$partitions"
		) USING(date)
	group by 1
),
pa as (
	select profile_id,
		popularity,
		credits_count,
		primary_genre,
		if(
			json_extract_scalar(top_role, '$.parent') = 'Organizations',
			json_extract_scalar(top_role, '$.child'),
			json_extract_scalar(top_role, '$.parent')
		) as main_role
	from (
			select profile_id,
				popularity,
				credits_count,
				primary_genre,
				try(array_sort(
					cast(json_extract(child_roles, '$') as array(json)),
					(a, b)->IF(
						coalesce(
							try_cast(json_extract_scalar(a, '$.credit_count') as int),
							0
						) < coalesce(
							try_cast(json_extract_scalar(b, '$.credit_count') as int),
							0
						),
						1,
						-1
					)
				) [1]) as top_role,
				row_number() over (
					partition by profile_id
					order by coalesce(popularity, 0)
				) as r_n
			from "platform-industry-calc-prod".profile_aggregations_full
				join (
					select max(build_timestamp) as build_timestamp
					from "platform-industry-calc-prod"."profile_aggregations_full$partitions"
				) USING(build_timestamp)
		)
	where r_n = 1
)
select 
-- popularity / 20 * 20 as popularity_rank,

-- 		main_role,
		primary_genre,
-- 	case
-- 		when streams > 10000000000 then '0: 10B+'
-- 		when streams > 1000000000 then '1: 1B+'
-- 		when streams > 100000000 then '2: 100M+'
-- 		when streams > 10000000 then '3: 10M+'
-- 		when streams > 1000000 then '4: 1M+' else '5: <1M'
-- 	end as streams_rank,
-- 	case
-- 		when credits_count > 10000 then '0: 10K+'
-- 		when credits_count > 1000 then '1: 1K+'
-- 		when credits_count > 300 then '2: 300+'
-- 		when credits_count > 100 then '3: 100+'
-- 		when credits_count > 10 then '4: 10+' else '5: <10'
-- 	end as credits_count,
	count(1) as num_subscriptions,
	count_if(is_active) as num_active,
	count_if(is_cancelled) as num_cancelled,
	count_if(is_suspended) as num_suspended,
	1.0 * count_if(is_suspended) / count_if(is_active) as suspended_to_active,
	1.0 * count_if(is_suspended OR is_cancelled) / count(1) as cancelld_to_all
from (
		select *,
			row_number() over (
				partition by teamid
				order by coalesce(is_claimed, FALSE) desc,
					coalesce(is_active_seat, FALSE) desc,
					coalesce(streams, 0) desc,
					coalesce(credits_count, 0) desc
			) as team_profile_rank
		from tp
			left join ps using (profile_id)
			left join pa using (profile_id)
	)
where team_profile_rank = 1
group by 1
order by 1