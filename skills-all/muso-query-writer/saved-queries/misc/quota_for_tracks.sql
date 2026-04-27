/*
id: quota_for_tracks
title: [songstats] Quota for tracks
athena_id: b4e61559-6d94-4e82-889b-83ea66607336
primary_tag: songstats
tags: [songstats]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with s AS (
	select trackid AS _id,
		isrc AS s_isrcs
	from "public_songstats_track_status"
	where date = '2023-09-16'
		and inprogress
		and lasterrormessage = 'You have already exceeded your allotted calls per month for this track'
)
select _id,
	isrcs,
	array_join(
		array_distinct(
			transform(
				filter(raw_recording_ids, r->r like 'spotify:%'),
				s->split_part(s, ':', 2)
			)
		),
		','
	) AS spotify_ids
from hive."platform-industry-bi-prod".matvw_catalog_track as t
	join s using(_id)