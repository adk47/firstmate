/*
id: profiles_inflated_left
title: [legacy analytics] Profiles inflated left
athena_id: b1874eb3-f188-4210-8e84-5d7db588b526
primary_tag: legacy-analytics
tags: [legacy-analytics]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with l as (
	select real_spotify_streams as rss,
		inflated_spotify_streams as iss,
		real_youtube_streams as rys,
		inflated_youtube_streams as iys,
		_id as profile_id
	from hive.default.matvw_dict_legacy_profile_stats
),
c as (
	select profile_id,
		ce_youtube_streams as cys,
		ce_spotify_streams as css,
		profile_name
	from "platform-industry-calc-prod".calc_analytics_cube_profile_history
	where date = '2024-06-24'
		and period = 'all'
)
select *
from (
		select profile_id,
			profile_name,
			COALESCE(iss, 0) - coalesce(css, 0) as spotify_diff,
			COALESCE(iys, 0) - coalesce(cys, 0) as youtube_diff,
			iss,
			css,
			iys,
			cys
		from l
			left join c USING(profile_id)
	)
where spotify_diff + youtube_diff > 0
	and profile_name is not null
order by spotify_diff + youtube_diff desc