/*
id: profile_popularity_bracket_streams
title: Profile Popularity bracket streams
athena_id: 2593ce60-9ac1-436d-96cb-6df0217610a7
primary_tag: misc
tags: [misc]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro AS (
	select s.seatid AS profile_id,
		BOOL_OR(COALESCE(s.status, '') = 'active') AS is_pro
	from postgresql_core.public.roster_seats AS s
	where teamid not in (select id from postgresql_core.public.teams where email like '%@muso.ai')
	group by 1
),
s AS (
	select profileid AS profile_id,
		SUM(
			COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
		) AS streams
	from postgresql_core.public."public_profile_track_stats"
	group by 1
)
select case
		when popularity > 79 then '80-100'
		when popularity > 59 then '60-79'
		when popularity > 39 then '40-59'
		when popularity > 19 then '20-39' else '0-19'
	end AS bracket,
	count(1) AS num_total,
	count(is_pro) AS num_subscribers,
	count_if(is_pro) AS num_pro,
	approx_percentile(streams, 0.5) AS streams_p50
from hive."platform-industry-bi-prod".matvw_catalog_profile
	left join pro ON(profile_id = _id)
	left join s USING(profile_id)
where not is_deleted
group by 1
order by 1 desc