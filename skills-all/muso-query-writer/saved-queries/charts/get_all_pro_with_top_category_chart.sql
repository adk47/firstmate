/*
id: get_all_pro_with_top_category_chart
title: [CHARTS] Get all pro with top category chart
athena_id: 51f8eea6-0f98-47fa-82f2-4a3376fc6a59
primary_tag: charts
tags: [charts]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro as (
	select distinct seatid AS profile_id
	FROM "production-musomvp"."public_discovery_seats"
	where status = 'active'
)
select profile_id,
	MAX(overall_score) AS overall_score,
	MAX_BY(chart, stats.score) AS top_chart,
	MAX(stats.score) AS top_chart_score,
	MAX(stats.track_count) AS top_chart_tracks
from calc_credit_score
	join pro USING(profile_id)
	cross join unnest(
		cast(
			JSON_EXTRACT(child_credit_score, '$') AS MAP(VARCHAR, ROW(score int, track_count int))
		)
	) AS j(chart, stats)
group by 1
order by 2 desc