/*
id: percentages_for_streams_and_credit_counts
title: [Encore24] Percentages for streams and credit counts
athena_id: 59746810-31cb-4d8a-b290-b72e82f352f3
primary_tag: encore
tags: [encore]
athena_database: platform-industry-calc-common-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pe as (
	select round(percentile / 100, 3) as p
	from (
			select ARRAY [ 99.9,
				99,
				98,
				97,
				96,
				95,
				94,
				93,
				92,
				91,
				90,
				85,
				80,
				75,
				70,
				65,
				60,
				55,
				50,
				40,
				30,
				20,
				10,
				9,
				8,
				7,
				6,
				5,
				4,
				3,
				2,
				1 ] as p
		)
		cross join unnest(p) as pc(percentile)
),
t as (
	select track_id,
		max_by(streams, date) as streams
	from "platform-stats-export-prod".public_track_daily
	group by 1
),
s as (
	select profile_id,
		sum(streams) as streams
	from "platform-stats-export-prod".public_profile_track as pt
		join t USING(track_id)
	group by 1
	having sum(streams) > 0
),
ps as (
	select p,
		approx_percentile(streams, p) as streams
	from s,
		pe
	group by 1
),
pc as (
	select p,
		approx_percentile(try_cast(credits_count as bigint), p) as credits_count,
		approx_percentile(try_cast(credits_count_1y as bigint), p) as credits_count_1y
	from "platform-industry-bi-prod".matvw_catalog_profile,
		pe
	where not is_deleted
		and try_cast(credits_count as bigint) > 0
		and try_cast(credits_count_1y as bigint) is not null
	group by 1
)
select *
from pc
	join ps USING(p)
order by p desc