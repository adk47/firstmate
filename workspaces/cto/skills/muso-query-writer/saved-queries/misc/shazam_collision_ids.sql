/*
id: shazam_collision_ids
title: [Issue] Shazam collision ids
athena_id: 3c2c22b3-b758-436d-b081-2e9913408618
primary_tag: issue
tags: [issue]
athena_database: platform-qobuz-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with l as (
    select 
        url,
        track_id,
        split_part(split_part(url, '/song/', 2), '/', 1) as new_id,
        external_id as old_id,
        created_timestamp,
        name,
        action_by
    from "platform-stats-export-prod".public_analytics_link 
    where 
        source='shazam' 
        and url like '%/song/%'
),
o as (select * from l where new_id <> old_id)
select 
    o1.old_id,
    o1.new_id as corrupted_id,
    o2.new_id,
    o1.name,
    o2.name
from o as o1 
join o as o2 ON (o1.new_id=o2.old_id)
limit 100