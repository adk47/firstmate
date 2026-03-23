/*
id: number_of_linked_profiles_with_sources
title: [stats] Number of linked profiles with sources
athena_id: 17787da0-443c-4d72-a89e-707e483df4e9
primary_tag: stats
tags: [stats]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    _id AS profile_id,
    arbitrary(name) AS name,
    count(1) AS num_raw_ids,
    arbitrary(common_credits) AS common_credits,
    max(popularity) AS popularity,
    array_agg(rid) AS raw_ids
  from "matvw_catalog_profile" 
 cross join unnest(raw_profile_ids) AS r(rid)
 where rid not like 'muso:%' and not is_deleted
 group by 1 
 order by 3 desc, 4 desc
 limit 1000