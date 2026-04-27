/*
id: profile_credits_export
title: [adhoc] Profile credits export
athena_id: 1569e846-dbae-4c84-b514-b18bfd102f5a
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select t._id as track_id,
	t.title,
	array_join(
		transform(
			artists,
			a->a.name
		),
		','
	) as artists,
	coalesce(t.popularity, 0) AS popularity,
	array_join(
		array_distinct(
			transform(
				catalog_credits,
				cc->cc.child
			)
		),
		','
	) as credits
from hive."platform-industry-bi-prod".matvw_catalog_master_credit as c
	join hive."platform-industry-bi-prod".matvw_catalog_track as t ON (t._id = c.master_track_id)
where profile_id = '1d4e45dd-b101-4dc8-9c37-df4566fb6bce'
	and not c.is_deleted
	and not t.is_deleted
order by popularity desc