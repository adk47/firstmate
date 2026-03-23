/*
id: credits_coverage_high_rank_profiles_tracks
title: [OKR] Credits Coverage High Rank profiles&tracks
athena_id: 3a1cb30c-17fc-4aa8-91b6-1f3f39c6e313
primary_tag: okr
tags: [okr]
athena_database: platform-industry-bi-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with _track AS (
	select distinct master_track_id
	from "platform-industry-bi-prod"."matvw_catalog_master_credit" AS c
		join "platform-industry-bi-prod"."matvw_catalog_profile" AS p ON (p._id = c.profile_id)
	where not c.is_deleted
		and not p.is_deleted
		and p.profile_type in ('artist', 'professional')
		and p.rank in (1, 2)
	union
	select _id AS master_track_id
	from "platform-industry-bi-prod"."matvw_catalog_track"
	where rank in (1, 2)
		and not is_deleted
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
	from "platform-industry-bi-prod"."matvw_catalog_master_credit"
		RIGHT JOIN _track USING(master_track_id)
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