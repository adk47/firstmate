/*
id: tidal_merged_profile_ids
title: [Export] Tidal merged profile ids
athena_id: 6f18bc92-1f9f-4f02-9374-a9ac3d837a0a
primary_tag: export
tags: [export]
athena_database: platform-industry-bi-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with mt as (
    select 
        _id as muso_id,
        array_agg(split_part(rid, ':', 2)) as tidal_ids,
        count(1) as num_tidal_ids,
        min(name) as name,
        max(credits_count) as credits_count,
        coalesce(max(popularity), 0) as popularity
    from "platform-industry-bi-prod".matvw_catalog_profile
    cross join unnest(raw_profile_ids) as pr(rid)
    where not is_deleted and rid like 'tidal:%' and try_cast(split_part(rid, ':', 2) as bigint) is not null
    group by 1
)
select 
    num_tidal_ids,
    array_join(tidal_ids, ', ') as tidal_ids,
    muso_id,
    name,
    credits_count,
    popularity
from mt 
where num_tidal_ids > 1
