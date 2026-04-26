/*
id: organization_credits_for_non_org_profiles_from_raw
title: [adhoc] Organization credits for non-org profiles from raw
athena_id: b129b286-8237-48a4-ab67-ea49e55826c7
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
		_id AS muso_profile_id, name, popularity, credits_count
	from matvw_catalog_profile
		cross join unnest(raw_profile_ids) AS r(rid)
	where not is_deleted
)
select 
    profile_id,
    name,
    popularity,
    num_muso_credits AS num_credits_affected,
    credits_count
FROM (
		select p.muso_profile_id AS profile_id,
		arbitrary(p.name) AS name,
		arbitrary(p.popularity) AS popularity,
		arbitrary(p.credits_count) AS credits_count,
			count_if(split_part(profile_id, ':', 1) = 'muso') AS num_muso_credits,
			count(1) AS num_credits
		from matvw_raw_recording_credit AS c
			join d USING(credit)
			join p USING(profile_id)
		group by 1
	)
	where coalesce(num_muso_credits, 0) > 0
order by num_credits_affected desc