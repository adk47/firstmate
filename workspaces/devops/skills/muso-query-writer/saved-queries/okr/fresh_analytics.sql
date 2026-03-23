/*
id: fresh_analytics
title: [OKR] Fresh Analytics
athena_id: 3b699f3a-ed8e-48ca-ad6a-0ec97498e3a1
primary_tag: okr
tags: [okr]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with pd AS (
	select profile_id,
		day,
		MIN(day) over (partition by profile_id) AS first_date,
		date_diff('day', day, updated_date) = 0
		AND 100 * cnt_updated / cnt_tracks > 95 AS is_on_time
	from (
			select DATE(date) AS day,
				profileid AS profile_id,
				cast(min(createdat) as TIMESTAMP) AS updated_date,
				MAX("trackscount") AS cnt_tracks,
				MAX("numtracksupdated") AS cnt_updated
			from "production-musomvp"."public_profile_analytics_stats_history"
			where date >= '2023-04-14'
			group by 1,
				2
		)
		where cnt_tracks > 0
)
select 100.0 * count_if(on_time_days = total_days) / count(1) AS OKR,
	count(1) AS num_profiles,
	count_if(on_time_days = total_days) AS num_ontime_profiles
from (
		select profile_id,
			count(1) AS total_days,
			count_if(is_on_time) AS on_time_days
		from pd
		where date_diff('day', first_date, day) > 2
			AND date_diff('day', day, current_date) < 30
		group by 1
	)
order by 1 desc