/*
id: profile_industry_wide_stats
title: [Research] Profile industry wide stats
athena_id: 99e51cf1-704d-4f52-89c8-8e5bf152d626
primary_tag: research
tags: [research]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p as (
	select 'ff7a7b1c-6e11-4390-b08e-e62de4bb16ca' as profile_id,
		'Jay' as name
	union all
	select 'c739e396-cc08-4a62-87be-793afc6aebf5' as profile_id,
		'Serban' as name
	union all
	select '96938bdc-a1d9-422b-b8bf-3f8fa854dea1' as profile_id,
		'Go_A' as name
	union all
	select 'a8e76f21-e41d-4eff-8564-835fa8312ae0' as profile_id,
		'Cauê Del Grande - random user' as name
	union all
	select '0ee95282-3e2f-4fdf-b437-1b63df52f3f7' as profile_id,
		'THANKYOUCHASE - Random user' as name
	union all
	select '4344a403-9120-48e8-9c1e-23a74880d3b8' as profile_id,
		'Killzbeatz UZ - Random user' as name
	union all
	select '1aba1efe-3618-4c7f-aa03-f5dddd49ef5d' as profile_id,
		'questbeatz - Random user' as name
	union all
	select '4da87bcf-94a7-4270-9f3e-adf5e5135f83' as profile_id,
		'Lako - Random user' as name
	union all
	select '1ef4bcf8-5987-44c9-a871-a933969ea82a' as profile_id,
		'NRG' as name
	union all
	select '389ce35b-b2b6-450a-839a-8256eb7fa57d' as profile_id,
		'Muserk' as name
),
pc as (
	select profile_id,
		count_if(
			from_unixtime(created_timestamp / 1000) < current_date - interval '3' month
		) as credits_cum_month3,
		count_if(
			from_unixtime(created_timestamp / 1000) < current_date - interval '2' month
		) as credits_cum_month2,
		count_if(
			from_unixtime(created_timestamp / 1000) < current_date - interval '1' month
		) as credits_cum_month1,
		count(1) as credits_cum_total,
		count_if(
			from_unixtime(created_timestamp / 1000) between current_date - interval '3' month
			and current_date - interval '1' month
		) as credits_dlt_month3,
		count_if(
			from_unixtime(created_timestamp / 1000) between current_date - interval '2' month
			and current_date - interval '1' month
		) as credits_dlt_month2,
		count_if(
			from_unixtime(created_timestamp / 1000) between current_date - interval '1' month
			and current_date
		) as credits_dlt_month1
	from "platform-industry-calc-common-prod".calc_profile_track_credits
		join p using(profile_id)
	group by 1
),
ps as (
	select profile_id,
		streams_total - streams_1y as streams_cum_year,
		streams_total - streams_3m as streams_cum_month3,
		streams_total - streams_1m as streams_cum_month1,
		streams_total,
		streams_1y,
		streams_3m,
		streams_1m
	from (
			select profile_id,
				MAX(IF(period = 'all', ce_streams, 0)) as streams_total,
				MAX(IF(period = '1y', ce_streams, 0)) as streams_1y,
				MAX(IF(period = '3m', ce_streams, 0)) as streams_3m,
				MAX(IF(period = '1m', ce_streams, 0)) as streams_1m
			from "platform-industry-calc-prod".calc_analytics_cube_profile_history
				join p using(profile_id)
			where date = cast(current_date - interval '2' day as varchar)
			group by 1
		)
)
select *
from p
	join pc using(profile_id)
	join ps USING(profile_id)
order by credits_cum_total desc