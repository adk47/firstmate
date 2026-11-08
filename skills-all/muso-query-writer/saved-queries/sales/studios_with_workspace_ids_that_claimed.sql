/*
id: studios_with_workspace_ids_that_claimed
title: [Sales] Studios with workspace IDs that claimed
athena_id: 21170e5f-d26a-4a6f-8f2b-058e509fa98f
primary_tag: sales
tags: [sales]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pt as (
    select 
         profileid as _id,
         array_join(array_agg(distinct teamid), ', ') as workspace_ids
    from postgresql_core.public.claiming
    where status = 'processed'
    group by 1
)
select 
    'https://muso.ai/profile/'||_id as muso_url,
    name,
    popularity,
    credits_count,
    workspace_ids as claimed_workspace_ids,
    common_credits,
    roles
from hive."platform-industry-bi-prod".matvw_catalog_profile
left join pt USING(_id)
where 
    not is_deleted 
    -- and _id = '1ef4bcf8-5987-44c9-a871-a933969ea82a'
    and profile_type = 'organization'
    and (
        cardinality(filter(common_credits, c->lower(c) like '%studio%')) > 0
        or cardinality(filter(roles, c->lower(c) like '%studio%')) > 0
    )
order by popularity desc, credits_count desc