/*
id: get_links_added_to_tracks_by_ops
title: [ML] Get links added to tracks by ops
athena_id: 9c57881f-86df-442f-bc79-7209648e23f0
primary_tag: ml
tags: [ml]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with tl_ops as (
	select regexp_extract(route, '.*track/(.*)/analytics-sources', 1) as track_id,
		json_extract_scalar(requestdata, '$.body.link') as link,
		max_by(requestmethod, createdat) as request_method,
		max(
			from_iso8601_timestamp(replace(createdat, ' ', 'T'))
		) as request_time,
		max_by(email, createdat) as request_by
	from postgresql_core.public.public_action_log
	where service = 'retool'
		and route like '%analytics-sources%'
	group by 1,
		2
),
tl as (
	select track_id,
	    title,
	    array_join(array_distinct(filter(transform(artists, a->a.name), n->nullif(n, '') is not null)), ',') AS artists,
		case
			when source = 'spotify' then 'https://open.spotify.com/track/' || external_id
			when source = 'youtube' then 'https://youtube.com/watch?v=' || external_id
			when source = 'tiktok' then 'https://www.tiktok.com/music/' || external_id
			when source = 'shazam' then 'https://www.shazam.com/track/' || external_id
			when source = 'soundcloud' then 'https://soundcloud.com/' || external_id
		end as link,
		external_id,
		from_unixtime(l.created_timestamp / 1000) as added_time
	from hive.default.matvw_analytics_link as l
		join hive.default.matvw_catalog_track as t ON (t._id = track_id)
	where not t.is_deleted
		and track_id in (
			select distinct track_id
			from tl_ops
		)
		and nullif(l.merged.merged_to_id, '') is null
)
select coalesce(tl.track_id, tl_ops.track_id) as track_id,
    title,
    artists,
	coalesce(tl_ops.link, tl.link) as link,
	if(lower(request_method) = 'delete', 'delete', 'add') as action,
	coalesce(request_time, added_time) as action_time,
	tl_ops.link is not null as is_done_by_ops,
	request_by
from tl
	full join tl_ops ON(
		tl.track_id = tl_ops.track_id
		and strpos(tl_ops.link, external_id) > 0
	)
where tl.link is not null
order by 1,
	2