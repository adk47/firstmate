/*
id: bmi_claimed_profiles_ipis
title: [Export] BMI Claimed profiles ipis
athena_id: 495da158-162e-4524-85b6-a322387459c6
primary_tag: export
tags: [export]
athena_database: platform-industry-bi-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with cl as (
    select distinct c.profileid as _id
    from "platform-core-backend-export-prod".public_claiming as c
    join "platform-core-backend-export-prod".public_teams as t ON (t.id=c.teamid) 
    where status = 'processed'
), 
m as (
    select
        cast(feedproviderspartyid as varchar) as mlc_id, 
        ipinamenumber as ipi, 
        fullname as mlc_full_name
    from "platform-industry-mlc-bi-prod".parties
    where ipinamenumber > 0
)
select 
    _id as muso_id,
    array_join(array_agg(distinct m.ipi), ', ') as ipis,
    bool_or(coalesce(c.profile_type,'')='organization') as is_company,
    min(name) as name,
    max(popularity) as popularity,
    max(credits_count) as credits_count
from "platform-industry-bi-prod".matvw_catalog_profile as c
join cl USING(_id)
cross join unnest(raw_profile_ids) as r(rid)
join m ON (rid='mlc:'||mlc_id)
where not is_deleted
group by 1 
order by 5 desc