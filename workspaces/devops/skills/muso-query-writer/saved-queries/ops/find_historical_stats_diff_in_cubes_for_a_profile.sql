/*
id: find_historical_stats_diff_in_cubes_for_a_profile
title: [ops] Find historical stats diff in cubes for a profile
athena_id: bb179643-b5eb-4af9-8d77-ec2f05f80db3
primary_tag: ops
tags: [ops]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    date,
    ce_streams,
    ce_youtube_streams,
    ce_soundcloud_streams,
    ce_spotify_streams
from calc_analytics_cube_profile_history 
where date > '2024-06-01' and profile_id = '1d01af63-36da-4ddd-a84a-24929771a006' and period = 'all'
order by date desc


with o as (
    select 
        date,
        track_id,
        ce_streams,
        ce_youtube_streams,
        ce_soundcloud_streams,
        ce_spotify_streams
    from calc_analytics_cube_track_history 
    where date = '2024-06-14' and profile_id = '065c09bf-0c18-47e2-a38b-0f684b32c0df' and period = 'all'
),
n as (
    select 
        date,
        track_id,
        ce_streams,
        ce_youtube_streams,
        ce_soundcloud_streams,
        ce_spotify_streams
    from calc_analytics_cube_track_history 
    where date = '2024-08-08' and profile_id = '065c09bf-0c18-47e2-a38b-0f684b32c0df' and period = 'all'
)
select 
    track_id,
    n.ce_streams,
    o.ce_streams
from n full outer join o using(track_id)
order by coalesce(o.ce_streams, 0) - coalesce(n.ce_streams, 0) desc