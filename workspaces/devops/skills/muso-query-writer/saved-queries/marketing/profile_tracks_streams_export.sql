/*
id: profile_tracks_streams_export
title: [marketing] Profile Tracks streams export
athena_id: ee76807e-83e1-42ce-b147-64af36588135
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-bi-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with a AS (
	select track_id AS _id,
		sum(streams) AS streams,
		sum(
			if(
				DATE(date) > date_add('day', -366, current_date),
				streams
			)
		) AS streams_last_year
	from (
			select trackid as track_id,
				date,
				max(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "platform-core-backend-export-prod"."public_profile_track_stats"
				join "platform-industry-bi-prod".matvw_catalog_master_credit ON (
					profile_id = profileid
					and trackid = master_track_id
				)
			where profileid = 'a5a5764a-a76c-4255-9967-4cbe69dcdcac'
			group by 1,
				2
		)
	group by 1
)
select _id AS track_id,
	title,
	TRY(date(from_unixtime(release_timestamp / 1000))) AS release_date,
	COALESCE(popularity, 0) AS track_popularity,
	array_join(isrcs, ', ') AS isrcs,
	array_join(
		array_distinct(
			filter(
				transform(artists, a->a.name),
				an->an is not null
			)
		),
		', '
	) AS artist_names,
	streams
from "platform-industry-bi-prod".matvw_catalog_track
	join a USING(_id)
where not is_deleted
order by streams desc