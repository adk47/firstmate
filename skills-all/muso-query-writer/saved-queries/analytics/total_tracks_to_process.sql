/*
id: total_tracks_to_process
title: [analytics] Total tracks to process
athena_id: fa5fb307-19a7-4402-8069-294d21173943
primary_tag: analytics
tags: [analytics]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with up AS (
	SELECT distinct profile_id
	FROM (
			-- team seats
			select distinct seatid AS profile_id,
				'roster_seats' AS tbl
			from "production-musomvp"."public_roster_seats"
			where status = 'active'
			union
			-- Seat IDs
			select distinct seatid AS profile_id,
				'discovery_seats' AS tbl
			FROM "production-musomvp"."public_discovery_seats"
			where status = 'active'
			union
			-- Demo / VIP
			select distinct profileid as profile_id,
				'demo' AS tbl
			FROM "production-musomvp"."public_muso_profiles"
		)
	WHERE try_cast(profile_id as uuid) is not null
)
select count(distinct t._id) AS num_tracks, count(distinct isrc) AS num_isrcs, count(1) as num_profile_track_isrcs
from hive."platform-industry-bi-prod".matvw_catalog_master_credit as c
	join up USING(profile_id)
	join hive."platform-industry-bi-prod".matvw_catalog_track AS t ON (c.master_track_id = t._id)
	cross join unnest(isrcs) AS i(isrc)