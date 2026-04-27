/*
id: rank_1_tracks_issues
title: [review] Rank 1 tracks issues
athena_id: c8355eeb-f4ab-41b6-a3cd-528dcecf7676
primary_tag: review
tags: [review]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select t._id AS track_id,
	ARBITRARY(t.popularity) AS track_popularity,
	ARBITRARY(t.title) AS track_title,
	ARBITRARY(
		array_join(transform(t.artists, a->a.name), ', ')
	) AS artists,
	ARBITRARY('https://credits.muso.ai/track/') || t._id AS muso_url,
	SUM(cardinality(catalog_credits)) AS num_profile_credits,
	cardinality(
		filter(
			flatten(array_agg(catalog_credits)),
			cr->cr.parent = 'Engineer'
		)
	) > 0 as has_engineers,
	cardinality(
		filter(
			flatten(array_agg(catalog_credits)),
			cr->cr.parent = 'Producers & Arrangers'
		)
	) > 0 as has_producers,
	cardinality(
		filter(
			flatten(array_agg(catalog_credits)),
			cr->cr.parent = 'Songwriter'
		)
	) > 0 as has_songwriters,
	cardinality(
		filter(
			arbitrary(t.raw_recording_ids),
			r->r like 'tidal:%'
		)
	) > 0 as has_tidal_links
from hive."platform-industry-bi-prod"."matvw_catalog_track" AS t
	left join hive."platform-industry-bi-prod"."matvw_catalog_master_credit" AS c ON (t._id = c.master_track_id)
where t.rank = 1
group by 1
order by 2 desc