/*
id: profiles_with_modified_credits
title: [stats] Profiles with modified credits
athena_id: 324d8d8b-38ac-4a1c-9c8d-a1e9f42140e5
primary_tag: stats
tags: [stats]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with m AS (
	select distinct split_part(profile_id, ':', 2) AS profile_id,
		IF(
			recording_id like 'muso:%',
			split_part(recording_id, ':', 2),
			t._id
		) AS master_track_id,
		TRUE as is_modified
	from "platform-industry-bi-prod".matvw_catalog_track AS t
		cross join unnest(raw_recording_ids) AS r(recording_id)
		right join "platform-industry-bi-prod".matvw_raw_recording_credit AS c USING(recording_id)
	where profile_id like 'muso:%'
)
select COALESCE(p.rank, 5) AS profile_rank,
	count(distinct profile_id) AS num_profiles,
	count(distinct IF(is_modified, profile_id)) AS num_modified_profiles,
	100.0 * count(distinct IF(is_modified, profile_id)) / count(distinct profile_id) AS profile_modified_pct,
	count(1) AS num_credits,
	count_if(is_modified) AS is_modified,
	100.0 * count_if(is_modified) / count(1) AS credits_modified_pct
from "platform-industry-bi-prod".matvw_catalog_master_credit AS c
	full outer join m USING(profile_id, master_track_id)
	join "platform-industry-bi-prod".matvw_catalog_profile AS p ON (profile_id = p._id)
where not p.is_deleted
group by 1
order by 1