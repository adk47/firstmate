/*
id: get_track_sources_in_activities
title: [analytics] Get track sources in activities
athena_id: 961c74e2-7016-4aa8-94f9-319068d9bcad
primary_tag: analytics
tags: [analytics]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select trackid,
	src
from "public_track_activities"
	cross join unnest(
		CAST(
			json_extract(sources, '$') AS ARRAY(
				ROW(
					sourceUrl varchar,
					source varchar,
					user varchar,
					count bigint
				)
			)
		)
	) AS s(src)
where trackid in (
		'42a749fc-b82a-40a0-b125-142d8005854f',
		'46567d16-a04b-48b3-9466-3c7807196b0b'
	)
	and src.source = 'youtube'