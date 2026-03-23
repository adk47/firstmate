/*
id: eoy_user_stats
title: EOY User Stats
athena_id: e7c9bed9-9ab2-4358-a83a-9b2d8c17efc9
primary_tag: misc
tags: [misc]
athena_database: sandbox-oleg
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with profile_streams AS (
	select SUM(streams) AS streams,
		SUM(shazams) AS shazams,
		SUM(tiktoks) AS tiktoks,
		MAX(streams_1y) AS streams_1y,
		MAX(shazams_1y) AS shazams_1y,
		MAX(tiktoks_1y) AS tiktoks_1y,
		profile_id,
		MAX(profile_name) AS profile_name,
		MAX(profile_type) AS profile_type,
		MAX(
			IF(
				cardinality(images) > 0,
				images [ 1 ].url,
				NULL
			)
		) AS profile_image
	from "sandbox-oleg"."adhoc_profile_streams_v3" AS s
		JOIN "sandbox-oleg"."catalog_document_neptune_profile" AS p ON(p._id = s.profile_id)
	group by profile_id
),
top_tracks AS (
	select profile_id,
		ARRAY [ MAX_by(title, IF(top = 1, streams_1y, NULL)),
		MAX_by(title, IF(top = 2, streams_1y, NULL)),
		MAX_by(title, IF(top = 3, streams_1y, NULL)) ] AS top_tracks
	from (
			select profile_id,
				track_title AS title,
				ROW_NUMBER() OVER(
					PARTITION BY profile_id
					ORDER BY streams_1y desc
				) AS top,
				streams_1y
			FROM "sandbox-oleg"."adhoc_profile_streams_v3"
		)
	GROUP BY profile_id
),
top_credits AS (
	select profile_id,
		ARRAY [ MAX_by(credit, IF(top = 1, streams_1y, NULL)),
		MAX_by(credit, IF(top = 2, streams_1y, NULL)),
		MAX_by(credit, IF(top = 3, streams_1y, NULL)) ] AS top_credits
	from (
			select profile_id,
				credit,
				ROW_NUMBER() OVER(
					PARTITION BY profile_id
					ORDER BY streams_1y desc
				) AS top,
				streams_1y
			FROM (
					select profile_id,
						credit,
						SUM(streams_1y) AS streams_1y
					FROM "sandbox-oleg"."adhoc_profile_streams_v3"
						CROSS JOIN UNNEST(credits) AS c(credit)
					Where lower(credit) <> 'artist member'
					group by 1,
						2
				)
		)
	GROUP BY profile_id
),
top_collabs AS (
	select profile_id,
		ARRAY [ MAX_by(name, IF(top = 1, streams_1y, NULL)),
		MAX_by(name, IF(top = 2, streams_1y, NULL)),
		MAX_by(name, IF(top = 3, streams_1y, NULL)) ] AS top_colabs
	from (
			select profile_id,
				name,
				ROW_NUMBER() OVER(
					PARTITION BY profile_id
					ORDER BY streams_1y desc
				) AS top,
				streams_1y
			FROM (
					select profile_id,
						name,
						SUM(streams_1y) AS streams_1y
					FROM "sandbox-oleg"."adhoc_profile_streams_v3"
						CROSS JOIN UNNEST(collaborators) AS c(name)
					group by 1,
						2
				)
		)
	GROUP BY profile_id
)
select profile_name,
	profile_type,
	COALESCE(
		CARDINALITY(FILTER(top_tracks, el->el is not null)),
		0
	) AS num_tracks,
	COALESCE(
		CARDINALITY(FILTER(top_credits, el->el is not null)),
		0
	) AS num_credits,
	COALESCE(
		CARDINALITY(FILTER(top_colabs, el->el is not null)),
		0
	) AS num_colabs,
	profile_image is NOT NULL AS has_profile_image,
	profile_image,
	streams,
	shazams,
	tiktoks,
	streams_1y,
	shazams_1y,
	tiktoks_1y,
	top_tracks,
	top_credits,
	top_colabs,
	profile_id
from profile_streams
	LEFT JOIN top_tracks USING(profile_id)
	LEFT JOIN top_collabs USING(profile_id)
	LEFT JOIN top_credits USING(profile_id)