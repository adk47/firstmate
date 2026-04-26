/*
id: audit_profiles_get_from_list_or_roster
title: [MLC] Audit Profiles get from list or roster
athena_id: 4daef644-da91-48c5-a350-8bd37f5af216
primary_tag: mlc
tags: [mlc]
trino_catalog: hive
trino_schema: audit
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    array_join(
        transform(
            array_agg(distinct seatid),
            s->'''' || s || ''''
        ),
        ','
    ) as ids
from postgresql_core.public.public_roster_seats
where teamid = 'be569d13-7b9e-4988-a0e4-ceba9cc693c8'




select 
    array_join(
        transform(
            array_agg(distinct seatid),
            s->'''' || s || ''''
        ),
        ','
    ) as ids
from postgresql_core.public.public_list_seats as ls
join postgresql_core.public.public_roster_seats as rs ON (rosterseatid=rs.id)
where listid = '8400409e-287f-45bb-977f-e833ef33693c'