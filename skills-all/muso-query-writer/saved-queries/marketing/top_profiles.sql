/*
id: top_profiles
title: [marketing] top profiles
athena_id: 4ce8db1c-8afb-4593-ac59-5f75ef07c5ec
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select *
from (
		select profile_id,
			arbitrary(name) AS name,
			min(position) AS top_position,
			max(credits_count) AS credits_count,
			min_by(
				category,
				row(position, if(category = 'Artist', 0, 1))
			) AS top_category
		from "platform-industry-calc-prod".calc_credit_score_charts_entries_history
		where date in (
				select max(date)
				from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
			)
			and category in (
				'Artist',
				'Producer',
				'Songwriter',
				'Mixing',
				'Mastering'
			)
			and profile_id not in (
				select distinct seatid as profile_id
				from postgresql_core.public.roster_seats
				where status = 'active'
					and teamid not in (
						select id
						from postgresql_core.public.teams
						where email like '%@muso.ai'
					)
				union
				select distinct profileid as profile_id
				from postgresql_core.public.claiming
				where status = 'processed'
			)
			and position <= 1000
		group by 1
	)
where top_category <> 'Artist'
order by top_position
limit 500