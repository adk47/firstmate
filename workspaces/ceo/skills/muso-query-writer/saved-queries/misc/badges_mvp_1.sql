/*
id: badges_mvp_1
title: [Growth] Badges MVP 1
athena_id: 88f4f1a6-5b0b-47a6-8d66-f623b1fada57
primary_tag: growth
tags: [growth]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro as (
	select distinct s.seatid AS profileid
	FROM "production-musomvp"."public_discovery_seats" AS s
		JOIN "production-musomvp"."public_users" AS u ON (s.userid = u.id)
	WHERE upper(u.subscriptionstatus) in ('PRO')
		and s."deletedat" is null
		and s.status = 'active'
		and s.seatid is not null
),
_ts AS (
	select profileid AS pid,
		trackid AS tid,
		SUM(COALESCE("spotifystreams", 0)) + SUM(COALESCE("soundcloudstreams", 0)) + SUM(COALESCE("youtubeviews", 0)) AS streams
	from "production-musomvp"."public_profile_track_stats"
		JOIN pro using (profileid)
	group by 1,
		2
),
ts AS (
	select pid,
		tid,
		case
			when streams > 10000000000 then 7
			when streams > 1000000000 then 6
			when streams > 100000000 then 5
			when streams > 10000000 then 4
			when streams > 1000000 then 3
			when streams > 100000 then 2
			when streams > 10000 then 1
		end AS badge,
		streams
	from _ts
)
select case
		when streams > 100000000000 then 'Crazy Diamond'
		when streams > 10000000000 then 'Diamond'
		when streams > 1000000000 then 'Platinum'
		when streams > 100000000 then 'Gold'
		when streams > 10000000 then 'Silver'
		when streams > 1000000 then 'Bronze'
		when streams > 100000 then 'Iron'
	end as profile_badge,
	*
from (
		select pid AS profile_id,
			count_if(badge = 7) AS crazy_diamond,
			count_if(badge = 6) AS diamond,
			count_if(badge = 5) AS platinum,
			count_if(badge = 4) AS gold,
			count_if(badge = 3) AS silver,
			count_if(badge = 2) AS bronze,
			count_if(badge = 1) AS iron,
			sum(streams) AS streams
		from ts
		group by 1
	)
order by streams desc