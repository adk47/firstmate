/*
id: top_albums_low_on_credits
title: [quality] Top albums low on credits
athena_id: 06daca27-1478-4968-9e37-4332113a96ca
primary_tag: quality
tags: [quality]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select *
from (
		SELECT 'https://credits.muso.ai/album/' || album_id AS album_url,
			max_by(r.title, r.popularity) AS title,
			max_by(
				array_join(transform(r.artists, a->a.name), ','),
				r.popularity
			) AS artists,
			MAX(COALESCE(r.popularity, 0)) AS popularity,
			SUM(coalesce(cardinality(t.profiles), 0)) / count(1) AS avg_credits_per_track,
			cardinality(
				filter(
					flatten(array_agg(raw_release_ids)),
					r->r like 'tidal:%'
				)
			) > 0 AS has_tidal
		from hive."platform-industry-bi-prod"."matvw_catalog_track" AS t
			join hive."platform-industry-bi-prod"."matvw_catalog_release" AS r ON (default_release_id = r._id)
		where NOT t.is_deleted
			and not r.is_deleted and r.release_type <> 'compilation'
		GROUP BY 1
	)
where avg_credits_per_track < 3
order by popularity desc,
	avg_credits_per_track
limit 1000