/*
id: top_users_by_chart_category
title: [marketing] Top users by chart category
athena_id: a607190c-f9f8-4d4a-9180-2f05a24496f1
primary_tag: marketing
tags: [marketing]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro AS (
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
					when credit.child in ('Mixing', 'Immersive Mixing') then 'Mixing'
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
	group by 1,
		2
),
s AS (
	select profile_id,
		SUM(streams) AS total_streams,
		MAP(
			ARRAY [ 'Songwriter',
			'Producer',
			'Mixing',
			'Mastering',
			'Bassist',
			'Drummer',
			'Keyboardist' ],
			ARRAY [ SUM(streams) filter (
				where contains(categories, 'Songwriter')
			),
			SUM(streams) filter (
				where contains(categories, 'Producer')
			),
			SUM(streams) filter (
				where contains(categories, 'Mixing')
			),
			SUM(streams) filter (
				where contains(categories, 'Mastering')
			),
			SUM(streams) filter (
				where contains(categories, 'Bassist')
			),
			SUM(streams) filter (
				where contains(categories, 'Drummer')
			),
			SUM(streams) filter (
				where contains(categories, 'Keyboardist')
			) ]
		) AS cat_stats
	from (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from postgresql_core.public."public_profile_track_stats"
			group by 1,
				2
			having date_diff(
					'day',
					DATE(SUBSTR(max(date), 1, 10)),
					current_date
				) <= 2
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
	total_streams,
	emails
from (
		select category,
			streams,
			profile_id,
			total_streams,
			row_number() over (
				partition by category
				order by streams desc
			) AS position,
			name,
			credits_count,
			emails
		from s
			join hive."platform-industry-bi-prod".matvw_catalog_profile ON (_id = profile_id)
			join pro USING(profile_id)
			cross join unnest(cat_stats) AS c(category, streams)
	)
where position <= 10
order by 1,
	2