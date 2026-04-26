/*
id: recent_released_tracks
title: [marketing] Recent released tracks
athena_id: 613151e4-9eca-4c1a-b53e-298fa29c869a
primary_tag: marketing
tags: [marketing]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 'https://credits.muso.ai/track/' || t._id AS track_url,
	arbitrary(t.title) AS title,
	ARRAY_JOIN(transform(arbitrary("artists"), a->a.name), ', ') AS artists,
	MAX(t.popularity) AS track_popularity,
	MAX(p.popularity) AS artist_popularity,
	MAX(
		DATE(
			from_unixtime(release_timestamp / 1000)
		)
	) AS release_date
from hive.default.matvw_catalog_track AS t
	cross join unnest(artists) AS a(artist)
	join hive.default.matvw_catalog_profile AS p ON (p._id = artist.catalog_profile_id)
where profile_type = 'artist'
	and p.rank in (1, 2)
	and date_diff(
		'day',
		DATE(
			from_unixtime(release_timestamp / 1000)
		),
		current_date
	) between 0 and 7
group by t._id
order by release_date desc,
	5 desc,
	4 desc
limit 1000