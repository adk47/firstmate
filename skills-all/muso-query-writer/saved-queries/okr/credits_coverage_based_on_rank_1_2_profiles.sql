/*
id: credits_coverage_based_on_rank_1_2_profiles
title: [OKR] Credits coverage based on Rank 1/2 profiles
athena_id: 34f610ff-ac70-4ce0-9d5f-e9ff1396f1fd
primary_tag: okr
tags: [okr]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with _profiles AS (
	select distinct _id as profile_id
	from hive."platform-industry-bi-prod"."matvw_catalog_profile"
	where rank in (1, 2)
		and profile_type in ('professional', 'artist')
),
tracks AS (
	select master_track_id,
		COUNT_IF(
			CARDINALITY(
				filter(
					catalog_credits,
					c->c.parent LIKE '%Producer%'
				)
			) > 0
		) > 0 AS has_producer,
		COUNT_IF(
			CARDINALITY(
				filter(
					catalog_credits,
					c->c.parent LIKE '%Engineer%'
				)
			) > 0
		) > 0 AS has_engineer,
		COUNT_IF(
			CARDINALITY(
				filter(
					catalog_credits,
					c->c.parent LIKE '%writer%'
				)
			) > 0
		) > 0 AS has_songwriter
	from hive."platform-industry-bi-prod"."matvw_catalog_master_credit"
		RIGHT JOIN _profiles USING(profile_id)
	GROUP BY 1
)
select 100.0 * count_if(
		has_engineer
		and has_songwriter
		and has_producer
	) / count(1) AS OKR,
	count(1) AS num_tracks,
	count_if(
		has_engineer
		and has_songwriter
		and has_producer
	) AS num_covered,
	count_if(has_engineer) AS num_engineer_covered,
	count_if(has_songwriter) AS num_songwriter_covered,
	count_if(has_producer) AS num_producer_covered
from tracks