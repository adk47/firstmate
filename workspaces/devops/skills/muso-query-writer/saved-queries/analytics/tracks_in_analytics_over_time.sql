/*
id: tracks_in_analytics_over_time
title: [Analytics] Tracks in analytics over time
athena_id: 1e4abf16-345f-48b1-9db6-0d8c075eeb58
primary_tag: analytics
tags: [analytics]
athena_database: platform-stats-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    date_trunc('month', DATE(start_date)) as month,
    sum(count(1)) over (order by date_trunc('month', DATE(start_date))) as tracks_number
from (
    select 
        track_id, 
        min(date) as start_date 
    from public_track_daily 
    group by 1 
)
group by 1
order by 1 desc