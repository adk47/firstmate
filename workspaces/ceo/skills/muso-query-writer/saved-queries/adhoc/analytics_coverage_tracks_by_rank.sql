/*
id: analytics_coverage_tracks_by_rank
title: [adhoc] Analytics Coverage Tracks by Rank
athena_id: b4d60b82-62eb-4315-8f21-9f16a28110b6
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with c AS (
select 
    distinct 'spotify:' || id AS rid, true as in_analytics
from "platform-industry-calc-prod".calc_analytics_history 
where capture_date >= '2024-02-01' and source='spotify'
)
select
    rank,
    num_tracks,
    num_analytics_tracks,
    round(100.0 * num_analytics_tracks / num_tracks, 3) AS pct_analytics
from (
select 
    coalesce(rank, 5) AS rank,
    count(distinct _id) AS num_tracks,
    count(distinct IF(in_analytics, _id)) AS num_analytics_tracks
from "platform-industry-bi-prod".matvw_catalog_track
cross join unnest(raw_recording_ids) AS r(rid)
left join c USING(rid)
group by 1
)
order by 1