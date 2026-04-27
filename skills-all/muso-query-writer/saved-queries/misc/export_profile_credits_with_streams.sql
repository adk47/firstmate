/*
id: export_profile_credits_with_streams
title: [User Request] Export profile credits with streams
athena_id: 620f3a61-59aa-43fd-b383-5a20b4121f16
primary_tag: user-request
tags: [user-request]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select t._id as muso_track_id,
	t.title as track_title,
	array_join(
		array_distinct(
			filter(transform(artists, a->a.name), n->n is not null)
		),
		', '
	) as artists,
	coalesce(streams, 0) AS streams,
	array_join(
		array_distinct(
			filter(
				transform(catalog_credits, c->c.child),
				c->c is not null
			)
		),
		', '
	) AS credits,
	array_join(array_distinct(isrcs), ', ') AS isrcs
from hive."platform-industry-bi-prod".matvw_catalog_master_credit as c
	join hive."platform-industry-bi-prod".matvw_catalog_track as t ON (t._id = c.master_track_id)
	left join (
		select track_id,
			ce_streams as streams
		from "platform-industry-calc-prod".calc_analytics_cube_track_history
		where date = cast(current_date - interval '1' day as varchar)
			and period = 'all'
			and profile_id = '2cbcec1e-01d2-b6c8-89a9-932e71a56e8c'
	) as a ON (c.master_track_id = track_id)
where profile_id = '2cbcec1e-01d2-b6c8-89a9-932e71a56e8c'
	and not t.is_deleted
order by streams desc,
	popularity desc