/*
id: audit_isrc
title: [MLC] Audit - isrc
athena_id: 48c42407-4c73-4c18-b2e5-7933cd701d62
primary_tag: mlc
tags: [mlc]
trino_catalog: hive
trino_schema: audit
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select isrc,
	mlc_codes,
	iswcs,
	max_spotify_streams,
	popularity,
	title,
	artists,
	spotify_url,
	tidal_url,
	muso_url,
-- 	track_id,
	is_registered,
	has_work,
	has_iswc,
	case
		when not is_registered then 'Unregistered Recording'
		when not has_work then 'Unmatched Recording' else 'No Issues'
	end as action,
	track_isrcs_with_work as other_track_isrcs_with_work,
	if(not has_work, predicted_missing_mlc_codes) as predicted_work
from hive.audit.audit_isrc
where cardinality(
		filter(
			writer_profile_ids,
			p->p in (
				'a64b188c-e2ac-4e14-bef5-3aa2a8e807e0'
			)
		)
	) > 0
	and NULLIF(spotify_url, '') is not null
order by popularity desc,
	max_spotify_streams desc