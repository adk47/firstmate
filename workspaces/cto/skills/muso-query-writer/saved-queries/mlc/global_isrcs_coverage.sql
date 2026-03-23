/*
id: global_isrcs_coverage
title: [MLC][Global] ISRCs coverage
athena_id: d96cbde4-0b22-46b7-9720-5d407aa4c687
primary_tag: mlc
tags: [mlc]
athena_database: audit-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    *,
    streams_total - streams_is_registered as streams_unregistered,
    streams_total - streams_has_work as streams_unmatched,
    1.0 * num_is_registered / num_total as pct_is_registered,
    1.0 * num_has_work / num_total as pct_has_work,
    1.0 * num_has_iswc / num_total as pct_has_iswc,
    1.0 * streams_is_registered / streams_total as pct_streams_is_registered,
    1.0 * streams_has_work / streams_total as pct_streams_has_work,
    1.0 * streams_has_iswc / streams_total as pct_streams_has_iswc
from (
    select 
        case 
            when popularity >= 80 then 1
            when popularity >= 50 then 2
            when popularity >= 10 then 3
            when popularity > 0 then 4
            else 5 end as rank,
        count(1) as num_total,
        count_if(is_registered) as num_is_registered,
        count_if(has_work) as num_has_work,
        count_if(has_iswc) as num_has_iswc,
        SUM(streams) as streams_total,
        sum(if(is_registered, streams, 0)) as streams_is_registered,
        sum(if(has_work, streams, 0)) as streams_has_work,
        sum(if(has_iswc, streams, 0)) as streams_has_iswc
    from "audit-prod".audit_isrc
    group by 1 
)
order by 1