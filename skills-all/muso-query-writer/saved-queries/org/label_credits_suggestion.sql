/*
id: label_credits_suggestion
title: [org] Label credits suggestion
athena_id: 2db49ed2-8c22-4d0e-844a-e6a9087ff01c
primary_tag: org
tags: [org]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with lr AS (
	select custom_data.label AS label,
		recording_id
	from hive.default.matvw_raw_release
		cross join unnest(
			array_distinct(transform(recordings, r->r.recording_id))
		) AS r(recording_id)
	where source = 'spotify'
		and custom_data.label in (
			'Boosted Entertainment',
			'Hitify'
-- 			,'Melodizer'
		)
),
c AS (
	select distinct master_track_id AS _id,
		true as already_added
	from hive.default.matvw_catalog_master_credit
	where profile_id = '71b4cc1d-7089-4a84-ae1f-87ef51bdd238'
)
select 'Boosted Entertainment' AS workspace_name,
	'Boosted Entertainment' AS org_name,
	'add_label_' || label AS track_status,
	title,
	array_join(
		array_distinct(transform(artists, a->a.name)),
		', '
	) AS artists,
	popularity,
	'https://credits.muso.ai/track/' || _id AS track_url
from hive.default.matvw_catalog_track AS t
	cross join unnest(raw_recording_ids) AS r(recording_id)
	join lr using(recording_id)
	left join c using(_id)
where not t.is_deleted
	and already_added is NULL
order by popularity desc