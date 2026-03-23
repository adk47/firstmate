/*
id: top_tracks_with_labels
title: [lablel] Top tracks with labels
athena_id: 09d0c00f-bd08-41a5-8e50-5e4ac3c37f03
primary_tag: lablel
tags: [lablel]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with lr AS (
	select custom_data.label AS label,
		rid
	from "platform-industry-bi-prod".matvw_raw_release
		cross join unnest(
			array_distinct(transform(recordings, r->r.recording_id))
		) AS r(rid)
	where source = 'spotify'
)
select 'https://credits.muso.ai/track/' || _id AS track_url,
	max(popularity) AS popularity,
	arbitrary(title) AS title,
	arbitrary(
		array_join(
			array_distinct(transform(artists, a->a.name)),
			', '
		)
	) AS artists,
	array_join(
		array_sort(array_distinct(array_agg(label))),
		', '
	) AS labels
from "platform-industry-bi-prod".matvw_catalog_track AS t
	cross join unnest(raw_recording_ids) AS r(rid)
	join lr USING(rid)
where not t.is_deleted
	and popularity > 50
group by 1
order by popularity desc
limit 10000