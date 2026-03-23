/*
id: credits_coverage
title: [OKR] Credits Coverage
athena_id: 9115ddbe-8f23-4654-ba2a-a5badb5b5efd
primary_tag: okr
tags: [okr]
athena_database: neptune-edges-json-production
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with _track AS (
	select _id AS master_track_id,
		case
			when popularity > 80 then 1
			when popularity > 60 then 2
			when popularity > 20 then 3
			when popularity > 0 then 4 else 5
		end AS track_rank
	from "platform-industry-bi-prod"."matvw_catalog_track"
	where not is_deleted
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
	from "platform-industry-calc-common-prod".calc_profile_track_credits
		RIGHT JOIN _track USING(master_track_id)
	GROUP BY 1
)
select track_rank,
	num_tracks,
	100.0 * num_covered / num_tracks as pct_covered,
	100.0 * num_songwriter_covered / num_tracks as pct_WRITER_covered,
	100.0 * num_producer_covered / num_tracks as pct_PROD_covered,
	100.0 * num_engineer_covered / num_tracks as pct_ENG_covered
from (
		select track_rank,
			100.0 * count_if(
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
			join _track USING(master_track_id)
		group by 1
	)