/*
id: albums_analytics_export
title: [Ops] Albums analytics export
athena_id: a3dd7a34-2025-4d2f-9b54-60c438304410
primary_tag: ops
tags: [ops]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with a as (
	select track_id,
		max(streams) as streams,
		max(shazams) as shazams,
		max(views) as views,
		max(videos) as videos
	from "platform-stats-export-prod".public_track_daily
	group by 1
),
al as (
	select r.album_id,
		t._id as track_id,
		MIN(r.title) as album_title,
		array_join(transform(arbitrary(r.artists), a->a.name), ',') as artists,
		array_agg(distinct upc) as upcs
	from hive.default.matvw_catalog_track as t
		cross join unnest(catalog_release_ids) as c(release_id)
		join hive.default.matvw_catalog_release as r ON(r._id = release_id)
	where not t.is_deleted
		and not r.is_deleted
		and cardinality(
			filter(
				profiles,
				p->p.profile_id = '4d698f13-0592-450a-a335-1177ab6d3a06'
			)
		) > 0
	group by 1,
		2
)
select album_id,
	arbitrary(album_title) as album_title,
	arbitrary(upcs) as upcs,
	max(streams) as streams,
	max(shazams) as shazams,
	max(views) as views,
	max(videos) as videos,
	array_agg(distinct track_id) as your_track_ids
from al
	join a USING(track_id)
group by 1
order by streams desc