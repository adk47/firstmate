/*
id: seats_songstats
title: [Reporting] Seats - SongStats
athena_id: 1d12c690-dfe0-47a0-8917-eed19fd201e8
primary_tag: reporting
tags: [reporting]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with seats AS (
	-- PRO users
	select distinct s.seatid as profile_id,
		u.fullname AS user,
		u.email AS user_email,
		IF(
			u.email LIKE '%muso.ai%',
			'MUSO',
			upper(u.subscriptionstatus)
		) AS user_current_status
	from "production-musomvp"."public_users" as u
		join "production-musomvp"."public_discovery_seats" as s on(u.id = s.userid)
	where upper(u.subscriptionstatus) in (
			'PRO',
			'TRIAL',
			'PENDING',
			'SUSPENDED',
			'CANCELLED'
		)
		and "createdatdate" < '2023-04-01'
		and (
			s."deletedat" is null
			or s."deletedat" >= '2023-03-01'
		)
		and s.status = 'active'
		and s.seatid is not null
	union
	-- demo/vip
	select distinct profileid AS profile_id,
		NULL AS user,
		NULL AS user_email,
		'DEMO' AS user_current_status
	from "production-musomvp"."public_muso_profiles"
),
profile AS (
	select "~id" AS profile_id,
	name,
		"commoncredits" AS common_credits,
		"creditcount" AS tracks_count
	from "neptune-nodes-json-production"."professional"
	union all
	select "~id" AS profile_id,
	name,
		'Artist' AS common_credits,
		"trackscount" AS tracks_count
	from "neptune-nodes-json-production"."artist"
)
select 
    profile_id,
    COALESCE(NULLIF(profile.name, ''), user) AS profile_name,
    common_credits,
    tracks_count
from seats left join profile USING(profile_id)