/*
id: get_copyright_tracks
title: [B2B] Get copyright tracks
athena_id: ba900773-7020-48a9-a003-48e404832602
primary_tag: b2b
tags: [b2b]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with rel as (
	select source_release_id,
		arbitrary(upc) AS upc,
		arbitrary(title) AS title,
		arbitrary(cr.name) AS copyright
	from "platform-industry-db-industry-prod"."raw_release"
		cross join unnest(copyrights) AS c(cr)
	where source = 'spotify'
		and lower(cr.name) like '%neon16%'
	group by 1
)
select distinct rel.source_release_id AS spotify_album_id,
	split_part(r_rec._id, ':', 2) AS spotify_track_id,
	ARBITRARY(rel.upc) AS upc,
	ARBITRARY(rel.title) AS release_title,
	ARBITRARY(rel.copyright) AS copyright,
	ARBITRARY(r_rec.isrc) as isrc,
	ARBITRARY(r_rec.title) AS recording_title,
	array_join(ARRAY_AGG(distinct r_p.name), ', ') AS recording_artists
from rel
	join hive."platform-industry-bi-prod"."matvw_raw_release" AS r_rel ON (r_rel.upc = rel.upc)
	cross join unnest(r_rel.recordings) AS rr(recording)
	join hive."platform-industry-bi-prod"."matvw_raw_recording" AS r_rec ON (r_rec._id = recording.recording_id)
	cross join unnest(r_rec.artist_ids) AS ra(raw_artist_id)
	join hive."platform-industry-bi-prod"."matvw_raw_profile" AS r_p ON (r_p._id = raw_artist_id)
where r_rel._id like 'spotify:%'
group by 1,2 