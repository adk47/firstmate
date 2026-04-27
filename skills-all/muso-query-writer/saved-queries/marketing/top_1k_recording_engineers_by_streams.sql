/*
id: top_1k_recording_engineers_by_streams
title: [marketing] Top 1K Recording Engineers by streams
athena_id: e46bc42b-69df-4489-9d57-52b377079d38
primary_tag: marketing
tags: [marketing]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with 
ptc AS (
	select _id as track_id,
		profile.profile_id
	from hive."platform-industry-bi-prod".matvw_catalog_track
		cross join unnest(profiles) AS p(profile)
		cross join unnest(profile.catalog_credits) AS c(credit)
		where credit.child = 'Engineer'
	group by 1,
		2
),
s AS (
	select profile_id,
		SUM(streams) AS total_streams,
		count(1) as num_recording_engineer_credits
	from (
			select profile_id,
				track_id,
				max_by(streams, date) as streams
			from hive."platform-industry-bi-prod".matvw_analytics_track_daily
				join ptc USING(track_id)
			group by 1,
				2
		)
		join ptc USING(track_id, profile_id)
	group by 1
)
select 
    name,
    array_join(common_credits, ', ') as common_credits,
    total_streams,
    popularity,
    num_recording_engineer_credits,
    credits_count as num_all_credits,
    'https://credits.muso.ai/profile/' || profile_id as muso_url
from s
join hive."platform-industry-bi-prod".matvw_catalog_profile as p ON (_id=profile_id)
order by total_streams desc 
limit 1000
