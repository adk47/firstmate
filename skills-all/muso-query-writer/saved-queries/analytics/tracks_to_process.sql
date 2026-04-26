/*
id: tracks_to_process
title: [analytics] # tracks to process
athena_id: f25ebe02-5a3d-45bd-93da-a4b2258bd3fd
primary_tag: analytics
tags: [analytics]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro AS (
	SELECT distinct profile_id
	FROM (
			-- team seats
			select distinct seatid AS profile_id
			from "production-musomvp"."public_roster_seats"
			where status = 'active'
			union
			-- Seat IDs
			select distinct seatid AS profile_id
			FROM "production-musomvp"."public_discovery_seats"
			where status = 'active'
			union
			-- Demo / VIP
			select distinct profileid as profile_id
			FROM "production-musomvp"."public_muso_profiles"
		)
	WHERE try_cast(profile_id AS uuid) IS NOT NULL
)
select count(distinct isrc) AS num_isrcs,
	count(distinct t._id) AS num_tracks,
	count(1) AS num_pairs
from pro
	join hive.default.matvw_catalog_master_credit as c USING(profile_id)
	join hive.default.matvw_catalog_track as t ON(c.master_track_id = t._id)
	cross join unnest(isrcs) AS i(isrc)