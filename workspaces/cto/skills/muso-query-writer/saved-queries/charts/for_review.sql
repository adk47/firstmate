/*
id: for_review
title: [charts] For review
athena_id: 5e903853-55a2-4c42-b6ac-cf938138b785
primary_tag: charts
tags: [charts]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select MIN_BY(category, position) AS category,
	profile_id,
	ARBITRARY(type) AS type,
	ARBITRARY(name) AS name,
	ARBITRARY(avatar_url) AS "avatar_url",
	MIN(position) AS position,
	MIN_BY(position_change, position) AS position_change,
	MIN_BY(score, position) AS score,
	MIN_BY(score_change, position) AS score_change,
	MIN_BY(credits_count, position) AS "credits_count",
	MIN_BY(credits_count_change, position) AS "credits_count_change",
	MIN_BY(date, position) AS "date"
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
	and position <= 105
-- 	and avatar_url is NULL
group by profile_id
order by position,
	category