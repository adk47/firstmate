/*
id: muso_credits_by_track_ranks
title: Muso Credits by Track Ranks
athena_id: acdc2302-e0a9-4528-83c3-c81675ef0d88
primary_tag: misc
tags: [misc]
athena_database: neptune-nodes-json-production
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- Total Tracks
-- Total tracks /w songwriter credits (total + coverage %)
-- Total tracks /w producer credits (total + coverage %)
-- Total tracks /w musician credits (total + coverage %)
-- Total tracks /w engineering credits (total + coverage %)
-- Total tracks /w visual credits (total + coverage %)
-- Total tracks /w management credits (total + coverage %)
-- Total tracks /w organization credits (total + coverage %)
-- Total tracks /w other credits (total + coverage %)
with track_credits AS (
	select track_id,
		percent_rank() over (
			order by coalesce(max(popularity), 0) desc
		) AS rank_pct,
		max(popularity) AS popularity,
		count(1) AS num_credits,
		count_if(is_admin_added) AS num_admin_credits,
		count_if(LOWER(parent) LIKE '%songwriter%') AS num_songwriter,
		count_if(LOWER(parent) LIKE '%producer%') AS num_producer,
		count_if(LOWER(parent) LIKE '%musician%') AS num_musician,
		count_if(LOWER(parent) LIKE '%engineer%') AS num_engineering,
		count_if(LOWER(parent) LIKE '%visual%') AS num_visual,
		count_if(LOWER(parent) LIKE '%management%') AS num_management,
		count_if(LOWER(parent) LIKE '%organi_ation%') AS num_org,
		count_if(LOWER(parent) LIKE '%other%') AS num_other
	from (
			(
				select "~from" AS collaborator_id,
					"~to" AS over_id,
					child,
					parent,
					LOWER("updatedby") LIKE '%admin%'
					or LOWER("createdby") LIKE '%admin%' AS is_admin_added
				from "neptune-edges-json-production"."collaborateover"
			)
			UNION
			(
				select "~from" AS collaborator_id,
					"~to" AS over_id,
					child,
					parent,
					LOWER("updatedby") LIKE '%admin%'
					or LOWER("createdby") LIKE '%admin%' AS is_admin_added
				from "neptune-edges-json-production"."performover"
			)
		) AS c
		join (
			select DISTINCT CAST("~id" AS VARCHAR) AS track_id,
				popularity
			from "neptune-nodes-json-production"."track"
		) as t ON(track_id = over_id)
	group by 1
)
select CASE
		WHEN rank_pct <= 0.001 THEN 1
		WHEN rank_pct <= 0.01 THEN 2
		WHEN rank_pct <= 0.1 THEN 3
		WHEN rank_pct <= 0.3 THEN 4 else 5
	end AS rank,
	count(1) AS num_tracks,
	sum(num_credits) AS num_credits,
	sum(num_admin_credits) AS num_admin_credits,
	count_if(num_songwriter > 0) AS num_songwriter,
	count_if(num_producer > 0) AS num_producer,
	count_if(num_musician > 0) AS num_musician,
	count_if(num_engineering > 0) AS num_engineering,
	count_if(num_visual > 0) AS num_visual,
	count_if(num_management > 0) AS num_management,
	count_if(num_org > 0) AS num_org,
	count_if(num_other > 0) AS num_other
from track_credits
group by 1