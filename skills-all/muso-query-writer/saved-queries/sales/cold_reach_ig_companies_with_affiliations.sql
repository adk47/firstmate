/*
id: cold_reach_ig_companies_with_affiliations
title: [Sales] Cold reach IG companies with affiliations
athena_id: 8b68cd3e-2b55-4460-a1e8-33c5166ad095
primary_tag: sales
tags: [sales]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with s as (
    select 
        seatid as _id,
        TRUE as is_in_seats,
        BOOL_OR(status='active') as is_pro,
        BOOL_OR(type='organization') as is_org
    from postgresql_core.public.roster_seats 
    group by 1
),
cl as (
    select 
        profileid as _id,
        TRUE as is_claiming_attempted,
        BOOL_OR(status='processed') as is_claimed
    from postgresql_core.public.claiming 
    group by 1
),
a as (
    select 
    _id,
    count(1) as num_collabs
    from (
        select distinct
            company_profile_id as _id,
            profile_id
        from "platform-industry-calc-prod".publisher_profile_relation_full 
        join (
            select max(build_timestamp) as build_timestamp 
            from "platform-industry-calc-prod"."publisher_profile_relation_full$partitions"
        ) USING(build_timestamp)
        union
        select distinct
            company_profile_id as _id,
            profile_id
        from "platform-industry-calc-prod".label_profile_relation_full 
        join (
            select max(build_timestamp) as build_timestamp 
            from "platform-industry-calc-prod"."label_profile_relation_full$partitions"
        ) USING(build_timestamp)
    )
    group by 1
),
ig AS (
    select c._id,
        arbitrary(contact.value) AS ig
    from hive."platform-industry-bi-prod".matvw_catalog_profile as c
        cross join unnest(raw_profile_ids) AS cr(rid)
        join hive."platform-industry-bi-prod".matvw_raw_profile AS r ON (r._id = rid)
        cross join unnest(r.contacts) AS rc(contact)
    where nullif(contact.value, '') is not null
        and contact.type = 'instagram'
    group by 1
)
select 
    _id,
    name,
    popularity,
    num_collabs as num_affiliations,
    roles,
    credits_count,
    ig
from hive."platform-industry-bi-prod".matvw_catalog_profile as p 
join a USING(_id)
join ig USING(_id)
left join s USING(_id)
left join cl USING(_id)
where 
    not is_deleted 
    and profile_type = 'organization'
    and is_in_seats is null 
    and is_claiming_attempted is null
    and popularity > 40
order by num_collabs desc, popularity desc
limit 1000