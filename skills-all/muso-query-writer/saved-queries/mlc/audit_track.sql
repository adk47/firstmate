/*
id: audit_track
title: [MLC] Audit - track
athena_id: 244a7836-3e54-452a-8c34-939632577b05
primary_tag: mlc
tags: [mlc]
athena_database: audit-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select *,
	case
		when nullif(mlc_isrcs, '') is null then 'ISRCs missing'
		when not has_work then 'Unmatched Recordings'
		when nullif(missing_isrcs, '') is not null then 'Some ISRCs missing'
		when nullif(iswcs, '') is null then 'ISWCs missing' else 'No Issues'
	end as action
from (
		select track_id,
			BOOL_OR(has_work) as has_work,
			array_join(
				array_distinct(flatten(array_agg(mlc_work_ids))),
				','
			) as mlc_codes,
			array_join(
				array_distinct(flatten(array_agg(iswcs))),
				','
			) as iswcs,
			MAX(track_streams) as streams,
			MAX(track_spotify_streams) as spotify_streams,
			MAX(track_youtube_streams) as youtube_streams,
			MAX(track_soundcloud_streams) as soundcloud_streams,
			MAX(track_popularity) as track_popularity,
			MIN(title) as title,
			MIN(artists) as artists,
			array_join(
				filter(array_agg(isrc), i->i is not null),
				','
			) as isrcs,
			array_join(
				filter(
					array_agg(IF(in_mlc, isrc)),
					i->i is not null
				),
				','
			) as mlc_isrcs,
			array_join(
				filter(
					array_agg(IF(not in_mlc, isrc, NULL)),
					i->i is not null
				),
				','
			) as missing_isrcs,
			array_join(
				filter(
					array_agg(
						distinct IF(
							isrc_spotify_id is not null,
							'https://open.spotify.com/track/' || isrc_spotify_id
						)
					),
					s->s is not null
				),
				', '
			) as spotify_urls,
			NOT BOOL_OR(in_mlc) as is_unregistered,
			NOT BOOL_AND(in_mlc) as is_missing_isrcs,
			NOT BOOL_OR(has_work) as is_missing_work,
			NOT BOOL_OR(has_iswc) as is_missing_iswcs,
			NOT BOOL_OR(has_publisher) as is_missing_publisher
		from "audit-prod".audit_isrc_track
		where cardinality(
				filter(
					profile_ids,
					p->p = '9e692a3a-ef21-4fe8-8e6a-cd83e100bf57'
				)
			) > 0
		group by 1
	)
order by streams desc,
	track_popularity desc