/*
id: verification_needed_profiles_intersection
title: [adhoc] Verification needed profiles intersection
athena_id: 332bdfa6-9abf-4533-b646-d7a6ee64afcb
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with v as (
	select distinct profileid,
		trackid
	from "production-musomvp".public_credit_requests
	where status = 'user_verification_needed'
	group by 1,
		2
),
c AS (
	select trackid,
		profile_id,
		profileid AS requested_profile_id,
		cardinality(filter(catalog_credits, c->c.parent='Artist')) > 0 AS is_track_artist
	from hive.default.matvw_catalog_master_credit
		right join v ON (master_track_id = trackid)
)
select count(distinct trackid) AS total_tracks,
	count(
		distinct if(profileid <> requested_profile_id or seatid <> requested_profile_id, trackid)
	) AS tracks_have_claimed_or_roster,
	count(
		distinct if(profileid <> requested_profile_id, trackid)
	) AS tracks_have_claimed,
	count(
		distinct if(profileid <> requested_profile_id and is_track_artist, trackid)
	) AS tracks_have_claimed_artist,
	count(
		distinct if(seatid <> requested_profile_id, trackid)
	) AS tracks_have_roster
from c
	left join "production-musomvp".public_claiming AS cl ON (
		profile_id = profileid
		and cl.status = 'processed'
	)
	left join "production-musomvp".public_roster_seats AS r ON (
		profile_id = seatid
		and r.status = 'active'
	)