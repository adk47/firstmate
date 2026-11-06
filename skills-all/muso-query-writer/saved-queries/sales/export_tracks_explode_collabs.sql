/*
id: export_tracks_explode_collabs
title: [Sales] Export tracks explode collabs
athena_id: e6848fa8-d892-490d-b436-6cc3ba717037
primary_tag: sales
tags: [sales]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with ta as (
	select track_id,
		count(1) as num_albums,
		array_join(array_agg(distinct title), ', ') as albums
	from "data-export-prod".album_track as t
		left join "data-export-prod".album as a ON (t.album_id = a.id)
	group by 1
),
t as (
	select t._id as track_id,
		p.name,
		ccc.role,
		'https://muso.ai/track/' || t._id as muso_url,
		cardinality(profiles) as num_collabs,
		title as song_name,
		array_join(transform(artists, a->a.name), ',') as song_artists,
		t.duration as length_in_seconds,
		date(from_unixtime(release_timestamp / 1000)) as date_released,
		array_join(
			array_distinct(transform(copyrights, c->c.name)),
			' / '
		) as copyrights,
		array_join(isrcs, ',') as isrcs,
		coalesce(t.popularity, 0) as track_popularity,
		array_join(
			transform(
				filter(raw_recording_ids, r->r like 'spotify:%'),
				sr->'https://open.spotify.com/track/' || split_part(sr, ':', 2)
			),
			' | '
		) as spotify_urls
	from hive."platform-industry-bi-prod".matvw_catalog_track as t
		cross join unnest(profiles) as tp(pc)
		join hive."platform-industry-bi-prod".matvw_catalog_profile as p ON (p._id = pc.profile_id)
		cross join unnest(array_distinct(transform(pc.catalog_credits, c->c.child))) as ccc(role)
	where cardinality(
			filter(
				t.profiles,
				p->p.profile_id in (
					'cf1b7118-e46c-403d-92be-e418ed283810',
					'2a00f8f5-2520-4bff-8fa7-bb36ff860641'
				)
			)
		) > 0
		and not t.is_deleted
		and ccc.role is not null
),
a as (
	select track_id,
		max_by(streams, date) as streams,
		max_by(spotify_streams, date) as spotify_streams,
		max_by(spotify_streams, date) - coalesce(
			max_by(
				spotify_streams,
				if(
					date(date) < current_date - interval '28' day,
					date
				)
			),
			0
		) as spotify_streams_28d
	from "platform-stats-export-prod".public_track_daily
	group by 1
)
select t.*,
	ta.*,
	a.*
from t
	left join ta USING(track_id)
	left join a USING(track_id)