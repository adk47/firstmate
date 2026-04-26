/*
id: organization_credits_source_vs_muso
title: [adhoc] Organization credits source vs muso
athena_id: b4f85e38-fa2a-445c-9edf-7a7305724841
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with d AS (
	select distinct _id AS credit
	from matvw_dict_credit
		cross join unnest(catalog_credits) as cc(c)
	where c.parent = 'Organizations'
),
p AS (
	select distinct rid AS profile_id,
		_id AS muso_profile_id
	from matvw_catalog_profile
		cross join unnest(raw_profile_ids) AS r(rid)
	where not is_deleted
)
select coalesce(num_muso_credits, 0) = 0 AS source_only,
	count(1) AS num_profiles,
	SUM(num_credits) AS num_credits
FROM (
		select p.muso_profile_id,
			count_if(split_part(profile_id, ':', 1) = 'muso') AS num_muso_credits,
			count(1) AS num_credits
		from matvw_raw_recording_credit AS c
			join d USING(credit)
			join p USING(profile_id)
		group by 1
	)
group by 1