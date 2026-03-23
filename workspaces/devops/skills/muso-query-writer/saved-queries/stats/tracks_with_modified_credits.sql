/*
id: tracks_with_modified_credits
title: [stats] Tracks with modified credits
athena_id: 6b2493e9-9bd8-436f-bb30-dc549be99439
primary_tag: stats
tags: [stats]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with m AS (
	select distinct profile_id,
		master_track_id,
		TRUE as is_modified
	from (
			select split_part(profile_id, ':', 2) AS profile_id,
				t._id AS master_track_id
			from "platform-industry-bi-prod".matvw_catalog_track AS t
				cross join unnest(raw_recording_ids) AS r(recording_id)
				right join "platform-industry-bi-prod".matvw_raw_recording_credit AS c USING(recording_id)
			where profile_id like 'muso:%'
			union all
			select split_part(profile_id, ':', 2) AS profile_id,
				split_part(recording_id, ':', 2) AS master_track_id
			from "platform-industry-bi-prod".matvw_raw_recording_credit
			where profile_id like 'muso:%'
				and recording_id like 'muso:%'
		)
)
select COALESCE(p.rank, 5) AS rank,
	count(distinct master_track_id) AS num,
	count(distinct IF(is_modified, master_track_id)) AS num_modified,
	100.0 * count(distinct IF(is_modified, master_track_id)) / count(distinct master_track_id) AS modified_pct,
	count(1) AS num_credits,
	count_if(is_modified) AS is_modified,
	100.0 * count_if(is_modified) / count(1) AS credits_modified_pct
from "platform-industry-bi-prod".matvw_catalog_master_credit AS c
	full outer join m USING(profile_id, master_track_id)
	join (
		select _id as master_track_id,
			rank
		from "platform-industry-bi-prod".matvw_catalog_track
		where not is_deleted
	) AS p USING (master_track_id)
group by 1
order by 1