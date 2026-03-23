/*
id: top_profiles
title: [EOY] TOP Profiles
athena_id: 842929d6-6f02-40af-b218-edd080ceecb7
primary_tag: eoy
tags: [eoy]
athena_database: platform-data-merging-growth-prod
description: Generate top profiles based on to 50K popular tracks requested from songstats
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with top_profiles AS (
	(
		select 'Artist' AS chart,
			profile_id,
			SUM(streams) AS total_streams,
			row_number() over (
				order by SUM(streams) desc
			) AS top
		from "sandbox-oleg"."industry_top_50k_isrc_profile"
		WHERE CONTAINS(parent_credits, 'Artist')
		group by 2
		order by 3 desc
		limit 10
	)
	union all
	(
		select 'Songwriter' AS chart,
			profile_id,
			SUM(streams) AS total_streams,
			row_number() over (
				order by SUM(streams) desc
			) AS top
		from "sandbox-oleg"."industry_top_50k_isrc_profile"
		WHERE CONTAINS(parent_credits, 'Songwriter')
		group by 2
		order by 3 desc
		limit 10
	)
	union all
	(
		select 'Producer' AS chart,
			profile_id,
			SUM(streams) AS total_streams,
			row_number() over (
				order by SUM(streams) desc
			) AS top
		from "sandbox-oleg"."industry_top_50k_isrc_profile"
		WHERE CONTAINS(parent_credits, 'Producers & Arrangers')
		group by 2
		order by 3 desc
		limit 10
	)
	union all
	(
		select 'Recording Engineer' AS chart,
			profile_id,
			SUM(streams) AS total_streams,
			row_number() over (
				order by SUM(streams) desc
			) AS top
		from "sandbox-oleg"."industry_top_50k_isrc_profile"
		WHERE CONTAINS(parent_credits, 'Engineer')
			AND CONTAINS(child_credits, 'Recording')
		group by 2
		order by 3 desc
		limit 10
	)
	union all
	(
		select 'Mixing Engineer' AS chart,
			profile_id,
			SUM(streams) AS total_streams,
			row_number() over (
				order by SUM(streams) desc
			) AS top
		from "sandbox-oleg"."industry_top_50k_isrc_profile"
		WHERE CONTAINS(parent_credits, 'Engineer')
			AND CONTAINS(child_credits, 'Mixing')
		group by 2
		order by 3 desc
		limit 10
	)
	union all
	(
		select 'Mastering Engineer' AS chart,
			profile_id,
			SUM(streams) AS total_streams,
			row_number() over (
				order by SUM(streams) desc
			) AS top
		from "sandbox-oleg"."industry_top_50k_isrc_profile"
		WHERE CONTAINS(parent_credits, 'Engineer')
			AND CONTAINS(child_credits, 'Mastering')
		group by 2
		order by 3 desc
		limit 10
	)
)
select chart,
	top,
	profile_id,
	name,
	common_credits,
	total_streams
from "platform-data-merging-catalog-prod"."catalog_industry_db_profile"
	JOIN top_profiles ON(profile_id = _id)
order by 1,
	2