/*
id: albums_coverage_by_popularity_for_analytics
title: [adhoc] Albums coverage by popularity for analytics
athena_id: 3e47ee0c-94a1-4ab5-8687-61acd29d32e6
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with r as (
select 
    default_release_id, 
    coalesce(max(popularity), 0) AS track_popularity,
    count(1) AS num_tracks
from hive."platform-industry-bi-prod".matvw_catalog_track
group by 1
)
select 
track_popularity,
count(1) AS num_albums,
sum(count(1)) over (order by track_popularity desc) as cum_albums,
sum(num_tracks) AS num_tracks,
sum(sum(num_tracks)) over (order by track_popularity desc) as cum_tracks
from r 
group by 1 
order by 1 desc