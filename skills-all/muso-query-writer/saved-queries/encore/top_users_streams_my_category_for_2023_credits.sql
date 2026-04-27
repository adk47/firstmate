/*
id: top_users_streams_my_category_for_2023_credits
title: [encore23] Top users streams my category for 2023 credits
athena_id: 91c97c9e-386d-4317-a493-85051eefb9f6
primary_tag: encore
tags: [encore]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with t23 AS (
	select _id AS track_id
	from hive."platform-industry-bi-prod".matvw_catalog_track
	where year(from_unixtime(release_timestamp / 1000)) = 2023
),
pro AS (
	select s.seatid AS profile_id,
		ARRAY_JOIN(ARRAY_AGG(distinct t.email), ', ') AS emails
	from postgresql_core.public.teams AS t
		join postgresql_core.public.roster_seats AS s ON (s.teamid = t.id)
	where s.status = 'active'
	group by 1
),
ptc AS (
	select master_track_id AS track_id,
		profile_id,
		filter(
			array_agg(
				distinct case
					when credit.parent = 'Songwriter' then 'Songwriter'
					when credit.child in ('Producer', 'Executive Producer', 'Co-Producer') then 'Producer'
					when credit.child in ('Mixing') then 'Mixing'
					when credit.child in ('Immersive Mixing') then 'Immersive Mixing'
					when credit.child in ('Mastering') then 'Mastering'
					when credit.parent = 'Musician'
					and credit.child in ('Bass') then 'Bassist'
					when credit.parent = 'Musician'
					and credit.child in ('Guitar') then 'Guitarist'
					when credit.parent = 'Musician'
					and credit.child in ('Drums') then 'Drummer'
					when credit.parent = 'Musician'
					and credit.child in ('Piano', 'Keyboard', 'Synthesizer') then 'Keyboardist'
				end
			),
			ct->ct is not null
		) as categories
	from hive."platform-industry-bi-prod".matvw_catalog_master_credit
		cross join unnest(catalog_credits) AS c(credit)
		join t23 ON (track_id = master_track_id)
	group by 1,
		2
),
s AS (
	select profile_id,
		SUM(streams) AS total_streams,
		cast(MAP(
			ARRAY [ 'Songwriter',
			'Producer',
			'Mixing',
			'Immersive Mixing',
			'Mastering',
			'Bassist',
			'Guitarist',
			'Drummer',
			'Keyboardist' ],
			ARRAY [ row(
				count_if(contains(categories, 'Songwriter')),
				SUM(streams) filter (
					where contains(categories, 'Songwriter')
				)
			),
			row(
				count_if(contains(categories, 'Producer')),
				SUM(streams) filter (
					where contains(categories, 'Producer')
				)
			),
			row(
				count_if(contains(categories, 'Mixing')),
				SUM(streams) filter (
					where contains(categories, 'Mixing')
				)
			),
			row(
				count_if(contains(categories, 'Immersive Mixing')),
				SUM(streams) filter (
					where contains(categories, 'Immersive Mixing')
				)
			),
			row(
				count_if(contains(categories, 'Mastering')),
				SUM(streams) filter (
					where contains(categories, 'Mastering')
				)
			),
			row(
				count_if(contains(categories, 'Bassist')),
				SUM(streams) filter (
					where contains(categories, 'Bassist')
				)
			),
			row(
				count_if(contains(categories, 'Guitarist')),
				SUM(streams) filter (
					where contains(categories, 'Guitarist')
				)
			),
			row(
				count_if(contains(categories, 'Drummer')),
				SUM(streams) filter (
					where contains(categories, 'Drummer')
				)
			),
			row(
				count_if(contains(categories, 'Keyboardist')),
				SUM(streams) filter (
					where contains(categories, 'Keyboardist')
				)
			) ]
		) AS MAP(varchar, row(c int, s bigint))) AS cat_stats
	from (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from postgresql_core.public."public_profile_track_stats"
			group by 1,
				2
-- 			having min(date) >= '2023-01-01'
		)
		join ptc USING(track_id, profile_id)
	group by 1
)
select category as chart,
	position,
	profile_id as id,
	name AS name,
	credits_count,
	streams,
	total_credits_count,
	total_streams,
	emails
from (
		select category,
			numbers.s as streams,
			profile_id,
			total_streams,
			row_number() over (
				partition by category
				order by numbers.s desc
			) AS position,
			name,
			numbers.c AS credits_count,
			credits_count as total_credits_count,
			emails
		from s
			join hive."platform-industry-bi-prod".matvw_catalog_profile ON (_id = profile_id)
			join pro USING(profile_id)
			cross join unnest(cat_stats) AS c(category, numbers)
	)
where position <= 10
order by 1,
	2