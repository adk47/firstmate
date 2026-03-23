/*
id: profile_streams_distribution
title: [adhoc] Profile streams distribution
athena_id: 973c521d-e89e-456b-82d7-a8eace7fe5d6
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p AS (
	select distinct seatid
	from public_roster_seats
	where status = 'active'
),
ps AS (
	select profileid,
		trackid,
		sum(spotifystreams) AS streams,
		100.0 * dense_rank() over (
			partition by profileid
			order by sum(spotifystreams)
		) / count() over (partition by profileid) AS pct
	from public_profile_track_stats
		JOIN p ON (seatid = profileid)
	where profileid in ('ff7a7b1c-6e11-4390-b08e-e62de4bb16ca')
	group by 1,
		2
)
select profileid,
	case
		when pct < 2.35 then 1
		when pct < 2.35 + 13.5 then 2
		when pct < 2.35 + 13.5 + 34 then 3
		when pct < 2.35 + 13.5 + 34 + 34 then 4
		when pct < 2.35 + 13.5 + 34 + 34 + 13.5 then 5 else 6
	end AS block,
	min(streams) AS min_streams,
	max(streams) AS max_streams
from ps
group by 1,
	2
order by 1,
	2