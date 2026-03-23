/*
id: adhoc_profile_streams_v1
title: adhoc_profile_streams_v1
athena_id: 2ead0337-ad9c-4b26-85d1-24347e951b96
primary_tag: misc
tags: [misc]
athena_database: sandbox-oleg
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

CREATE TABLE "sandbox-oleg"."adhoc_profile_streams_v3" WITH (
	external_location = 's3://databaseslake/sandbox-oleg/adhoc/adhoc_profile_streams_v3/',
	format = 'JSON'
) AS with usr AS (
	select distinct id AS userid
	from "production-musomvp"."public_users"
	WHERE subscriptionstatus = 'PRO'
),
profiles AS (
	select distinct seatid AS profile_id
	from usr
		JOIN "production-musomvp"."public_discovery_seats" using(userid)
	WHERE status = 'active'
		and NULLIF("deletedat", '') is NULL
		and NULLIF("seatid", '') is not NULL
),
track_stats AS (
	select trackid as track_id,
		SUM(streams) AS streams,
		SUM(shazams) AS shazams,
		SUM(tiktoks) AS tiktoks,
		SUM(
			IF(
				date >= '2022-01-01',
				streams,
				0
			)
		) AS streams_1y,
		SUM(
			IF(
				date >= '2022-01-01',
				shazams,
				0
			)
		) AS shazams_1y,
		SUM(
			IF(
				date >= '2022-01-01',
				tiktoks,
				0
			)
		) AS tiktoks_1y
	from (
			SELECT date,
				trackid,
				COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0) AS streams,
				shazams,
				tiktokviews AS tiktoks
			FROM "production-musomvp"."public_track_stats"
		)
	group by 1
)
select profiles.profile_id,
	ts.track_id,
	MAX(p.type) AS profile_type,
	MAX(p.name) AS profile_name,
	MAX(t.title) AS track_title,
	MAX(streams) AS streams,
	MAX(shazams) AS shazams,
	MAX(tiktoks) AS tiktoks,
	MAX(streams_1y) AS streams_1y,
	MAX(shazams_1y) AS shazams_1y,
	MAX(tiktoks_1y) AS tiktoks_1y,
	ARRAY_DISTINCT(
		flatten(ARRAY_AGG(TRANSFORM(credits, c->c.child)))
	) AS credits,
	ARRAY_AGG(distinct cp.name) AS collaborators
from profiles
	LEFT JOIN "sandbox-oleg"."catalog_document_neptune_profile" AS p ON(p._id = profiles.profile_id)
	LEFT JOIN "sandbox-oleg"."catalog_document_neptune_credit" AS c ON(c.profile_id = profiles.profile_id)
	LEFT JOIN "sandbox-oleg"."catalog_document_neptune_track" AS t ON (c.master_id = t.master_id)
	LEFT JOIN track_stats AS ts ON(t._id = ts.track_id)
	LEFT JOIN "sandbox-oleg"."catalog_document_neptune_collaboration" AS co ON(
		c.profile_id = co.profile_id
		and contains(master_ids, t.master_id)
	)
	LEFT JOIN "sandbox-oleg"."catalog_document_neptune_profile" AS cp ON(cp._id = collaborator_id)
group by 1,
	2