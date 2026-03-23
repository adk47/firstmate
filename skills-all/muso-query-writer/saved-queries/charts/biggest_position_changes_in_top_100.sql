/*
id: biggest_position_changes_in_top_100
title: [charts] Biggest position changes in top 100
athena_id: 3620b318-a66a-4175-afa0-19f180502a03
primary_tag: charts
tags: [charts]
athena_database: platform-industry-db-industry-dev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select position_change AS change, name, *
from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
where date in (
		select max(date)
		from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
	)
	and category not in (
		'Artist',
		'Engineer',
		'Assistant Engineer'
	)
	and position <= 100
order by abs(change) desc