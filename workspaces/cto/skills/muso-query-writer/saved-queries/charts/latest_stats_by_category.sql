/*
id: latest_stats_by_category
title: [Charts] Latest stats by category
athena_id: 5658fd6b-dd2e-49fb-84ff-fb1eed173ca7
primary_tag: charts
tags: [charts]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select category,
	count(1) AS num_profiles,
	count_if(score > 0) AS num_with_score,
	max(score) AS max_score,
	max(if(position = 100, score)) AS top_100_score,
	max(if(position = 1000, score)) AS top_1K_score,
	approx_percentile(score, 0.50) AS median_score,
	avg(score) AS avg_score,
	approx_percentile(score, 0.90) AS p90_score,
	approx_percentile(score, 0.99) AS p99_score
from "calc_credit_score_charts_entries_history"
where date in (
		select max(date)
		from "calc_credit_score_charts_entries_history$partitions"
	)
	and category <> 'Artist'
group by 1
order by 2 desc