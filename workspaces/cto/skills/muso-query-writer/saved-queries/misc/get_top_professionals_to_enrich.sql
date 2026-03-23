/*
id: get_top_professionals_to_enrich
title: [Migration] Get top professionals to enrich
athena_id: c4541054-f426-4c63-a386-2671e9327d6e
primary_tag: migration
tags: [migration]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro as (
	SELECT distinct profile_id AS pro_profile_id
	FROM (
			-- team seats
			select distinct seatid AS profile_id
			from "production-musomvp"."public_roster_seats"
			WHERE status = 'active'
			union
			-- Neptune Professional IDs
			select distinct neptuneprofessionalid AS profile_id
			from "production-musomvp"."public_users"
			WHERE upper(subscriptionstatus) in ('PRO')
			union
			-- Seat IDs
			select distinct seatid AS profile_id
			FROM "production-musomvp"."public_discovery_seats"
			WHERE status = 'active'
			union
			-- Demo / VIP
			select distinct profileid as profile_id
			FROM "production-musomvp"."public_muso_profiles"
		)
	WHERE try_cast(profile_id AS uuid) IS NOT NULL
),
_track AS (
	select "~id" AS track_id,
		COALESCE(popularity, 0) AS popularity
	from "neptune-nodes-json-production"."track"
),
pt AS (
	select "~from" AS profile_id,
		track_id,
		max(popularity) AS popularity,
		row_number() over (
			partition by "~from"
			order by max(popularity) desc
		) AS row_num
	from "neptune-edges-json-production"."collaborateover"
		JOIN _track ON("~to" = track_id)
	where lower(parent) LIKE '%producer%'
		or lower(parent) LIKE '%engineer%'
		or lower(parent) LIKE '%writer%'
		or lower(child) like '%producer%'
	GROUP BY 1,
		2
)
select profile_id,
	arbitrary(name) AS name,
	arbitrary(
		filter(
			IF(
				tidalid LIKE '[%]',
				CAST(try(json_parse(tidalid)) AS ARRAY(VARCHAR)),
				ARRAY [ tidalid ]
			),
			i->try_cast(i AS bigint) IS NOT NULL
		)
	) AS tidal_ids,
	sum(pt.popularity) AS sum_popularity
from pt
	join "neptune-nodes-json-production"."professional" AS p ON (profile_id = "~id")
	left join pro ON (pro_profile_id = profile_id)
where row_num < 100
	and pro_profile_id IS NULL
group by profile_id
order by sum(pt.popularity) desc
limit 1000