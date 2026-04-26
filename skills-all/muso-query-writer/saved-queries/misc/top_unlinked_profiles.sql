/*
id: top_unlinked_profiles
title: [catalog] Top unlinked profiles
athena_id: 69e45618-4771-43f2-9a21-10a998462cc4
primary_tag: catalog
tags: [catalog]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with rc as (
	select profile_id as pid,
		count(1) as num_credits
	from matvw_raw_recording_credit
	where recording_id not like 'spotify:%'
		and recording_id not like 'muso:%'
		group by 1
)
select 
    rp._id,
    rp.name,
    rp.profile_type,
    num_credits,
    rp.url
from matvw_catalog_profile AS p
cross join unnest(raw_profile_ids) AS r(pid)
right join rc using(pid)
join matvw_raw_profile AS rp ON (pid=rp._id)
where p._id is null and rp.url is not null
order by num_credits desc 
limit 10000