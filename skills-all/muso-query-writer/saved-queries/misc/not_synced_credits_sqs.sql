/*
id: not_synced_credits_sqs
title: [sync] Not synced credits SQS
athena_id: 82256eda-3d9e-4223-a5a7-ff455efc9969
primary_tag: sync
tags: [sync]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with credits AS (
	select distinct profile_id,
		master_track_id AS track_id
	from hive."platform-industry-bi-prod"."matvw_catalog_master_credit" as c -- cross join unnest("catalog_credits") AS cc(credit)
	where not coalesce(is_deleted, false)
),
_rp AS (
	select raw_profile_id,
		_id AS profile_id
	from hive."platform-industry-bi-prod"."matvw_catalog_profile"
		cross join unnest(raw_profile_ids) AS r(raw_profile_id)
	where not is_deleted
),
_rt AS (
	select 
        recording_id,
        rank,
        _id AS track_id
    from hive."platform-industry-bi-prod"."matvw_catalog_track"
    cross join unnest(raw_recording_ids) AS r(recording_id)
    where not coalesce(is_deleted, false)
		and COALESCE(rank, 5) = 5
),
cred_del AS (
	select distinct substr(profile_id, 6) AS profile_id,
		substr(recording_id, 6) AS track_id
	from hive."platform-industry-bi-prod"."matvw_raw_recording_credit"
	where profile_id like 'muso:%'
		and recording_id like 'muso:%'
		and is_deleted
),
final as (
	select _rp.profile_id,
		_rt.track_id
	from hive."platform-industry-bi-prod"."matvw_raw_recording_credit" AS c
		join _rp ON (
			c.profile_id = _rp.raw_profile_id
		)
		join _rt ON (
			c.recording_id = _rt.recording_id
		)
		left join credits AS cc ON (
			_rp.profile_id = cc.profile_id
			and _rt.track_id = cc.track_id
		)
		left join cred_del AS d ON (
			_rp.profile_id = d.profile_id
			and _rt.track_id = d.track_id
		)
	where d.profile_id is null
		and cc.profile_id is null
	group by 1,
		2
)
select 'sync' AS action_type,
	cast(
		ROW('credit_recording', NULL) AS row(entity_type varchar, entity_id varchar)
	) AS entity,
	cast(
		ROW('muso:' || profile_id, 'muso:' || track_id) AS row(profile_id varchar, recording_id varchar)
	) AS data
from final