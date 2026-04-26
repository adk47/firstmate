/*
id: exact_track_dups
title: [merge] Exact track dups
athena_id: a4c15acf-6246-4d1c-96c0-6da2ff01f1ce
primary_tag: merge
tags: [merge]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- FOUND ~50K of tracks like this
with t as (
	select _id,
		title,
		array_sort(
			array_distinct(filter(raw_recording_ids, r->r like 'spotify:%'))
		) AS spotify_ids,
		popularity,
		cardinality(raw_recording_ids) AS num_raw_ids
	from hive.default."matvw_catalog_track"
	where not COALESCE(is_deleted, FALSE)
)
select 'merge' AS action_type,
	cast(
		ROW('track', main_id) AS row(entity_type varchar, entity_id varchar)
	) AS entity,
	cast(
		ROW(array_except(ids, ARRAY [ main_id ])) AS row(merge_ids array(varchar))
	) AS data,
	*
from (
		select MAX_BY(_id, row(popularity, num_raw_ids, _id)) AS main_id,
			max(popularity) AS popularity,
			MAX_BY(title, row(popularity, num_raw_ids, _id)) AS title,
			ARRAY_AGG(_id) AS ids,
			spotify_ids
		from t
		where cardinality(spotify_ids) > 0
		group by spotify_ids
		having count(1) > 1
	)
where cardinality(array_except(ids, ARRAY [ main_id ])) > 0
order by popularity desc,
	title asc