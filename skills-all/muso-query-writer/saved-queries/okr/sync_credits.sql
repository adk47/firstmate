/*
id: sync_credits
title: [OKR] Sync % (credits)
athena_id: 38162349-b50e-4d2c-8568-e232a760e9b3
primary_tag: okr
tags: [okr]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with r as (
	select distinct profile_id,
		recording_id,
		lower(cat_cred.child) AS child
	from hive.default."matvw_raw_recording_credit" AS c
		join "platform-industry-db-industry-prod"."dict_credit" AS d ON (c.credit = d._id)
		cross join unnest(d.catalog_credits) AS cc(cat_cred)
	where not coalesce(c.is_deleted, false)
),
m AS (
	select distinct split_part(profile_id, ':', 2) AS profile_id,
		split_part(recording_id, ':', 1) AS track_id,
		credit AS child,
		TRUE AS muso_deleted
	from hive.default."matvw_raw_recording_credit"
	where is_deleted
		and profile_id like 'muso:%'
		and recording_id like 'muso:%'
),
c as (
	select distinct raw_profile_id AS profile_id,
		recording_id,
		lower(credit.child) AS child,
		TRUE AS in_catalog
	from hive.default."matvw_catalog_master_credit" AS c
		join hive.default."matvw_catalog_profile" AS p ON (p._id = c.profile_id)
		join hive.default."matvw_catalog_track" AS t ON (t._id = c.master_track_id)
		cross join unnest(catalog_credits) as cc(credit)
		cross join unnest(raw_profile_ids) as rp(raw_profile_id)
		cross join unnest(raw_recording_ids) as tr(recording_id)
),
counts as (
	select split_part(recording_id, ':', 1) AS source,
		count(1) as num_raw,
		count_if(in_catalog) as num_synced
	from r
		left join c USING(profile_id, recording_id, child)
	group by 1
)
select source,
	num_raw,
	num_synced,
	100.0 * num_synced / num_raw as percentage,
	100.0 * SUM(num_synced) over () / SUM(num_raw) over() as overall_percent
from counts