/*
id: teams_list
title: [B2B] Teams List
athena_id: e3414b60-9b66-469f-a850-6bd858b68867
primary_tag: b2b
tags: [b2b]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- select * from "public_profile_analytics_stats_history"  limit 10
with pti AS (
	select profileid AS profile_id,
		trackid AS track_id,
		i.isrc
	from "production-musomvp"."public_profile_track_stats"
		cross join unnest(SPLIT(substr(isrc, 2, LENGTH(isrc) -2), ',')) AS i(isrc)
	where date(date) = DATE_ADD('day', -2, DATE(now()))
),
ps AS (
	select profile_id AS seatid,
		count(distinct track_id) AS num_tracks,
		count(distinct isrc) AS num_isrcs
	from pti
	group by 1
)
select t.id || ' ' || t.name || '(' || t.email || ')' AS team,
	count(distinct seatid) AS num_seats,
	sum(num_tracks) AS num_tracks,
	sum(num_isrcs) AS num_isrcs
from "production-musomvp"."public_roster_seats" AS rs
	join "production-musomvp"."public_teams" AS t on(t.id = rs.teamid)
	join ps USING(seatid)
where status = 'active'
group by 1
order by 2 desc