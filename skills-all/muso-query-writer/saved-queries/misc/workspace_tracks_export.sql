/*
id: workspace_tracks_export
title: [customer] Workspace tracks export
athena_id: 094e098a-4d01-48a1-a05e-448751307de3
primary_tag: customer
tags: [customer]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with s as (
	select distinct seatid AS profile_id
	from "production-musomvp".public_roster_seats
	where teamid = '8ef48106-8b6d-44a6-8877-e16623407718'
		and status = 'active'
),
a AS (
	select track_id AS _id,
		sum(streams) AS streams,
		sum(
			if(
				DATE(date) > date_add('day', -366, current_date),
				streams
			)
		) AS streams_2023
	from (
			select trackid as track_id,
				date,
				max(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "production-musomvp"."public_profile_track_stats"
				join s ON(profileid = profile_id)
			group by 1,
				2
		)
	group by 1
),
c AS (
	select master_track_id AS _id,
		profile_id,
		transform(catalog_credits, c->c.child) AS child_credits,
		p.name AS profile_name
	from hive."platform-industry-bi-prod".matvw_catalog_master_credit
		join s USING(profile_id)
		join hive."platform-industry-bi-prod".matvw_catalog_profile AS p ON (p._id = profile_id)
)
select profile_id AS roster_profile_id,
	profile_name AS roster_profile_name,
	child AS credit,
	_id AS track_id,
	title,
	TRY(date(from_unixtime(release_timestamp / 1000))) AS release_date,
	COALESCE(popularity, 0) AS track_popularity,
	array_join(isrcs, ', ') AS isrcs,
	artist.name AS artist_name,
	streams,
	IF(
		streams > streams_2023,
		cast(
			ROUND(100.0 * streams_2023 / (streams - streams_2023), 1) AS VARCHAR
		) || '%',
		'N/A'
	) AS streams_ytd_pct
from hive."platform-industry-bi-prod".matvw_catalog_track
	join a USING(_id)
	join c USING(_id)
	cross join unnest(artists) AS a(artist)
	cross join unnest(child_credits) AS cc(child)
where not is_deleted