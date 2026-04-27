/*
id: unique_metadata
title: [OKR] Unique Metadata
athena_id: 2b4e2d53-23c9-49a2-a485-0823aecc9366
primary_tag: okr
tags: [okr]
athena_database: neptune-edges-json-production
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select count(1) AS cnt_changes,
	count(distinct profile_id) AS cnt_profiles
from hive."platform-industry-bi-prod"."matvw_raw_recording_credit"
where (
		recording_id like 'muso:%'
		or profile_id like 'muso:%'
	)
	and DATE_DIFF(
		'day',
		TRY(
			cast(
				from_unixtime(updated_timestamp / 1000) as date
			)
		),
		CURRENT_DATE
	) < 30