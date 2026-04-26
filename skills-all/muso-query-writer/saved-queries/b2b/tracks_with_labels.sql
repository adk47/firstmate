/*
id: tracks_with_labels
title: [B2B] Tracks with labels
athena_id: 950ad686-ffaf-436a-b9d1-c71ea5bb12c0
primary_tag: b2b
tags: [b2b]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with lr as (
    select 
    distinct
        label,
        raw_recording_id,
        album_id
    from hive.default.matvw_catalog_release
    cross join unnest(recording_ids) as r(raw_recording_id)
    where release_type in ('single', 'album') and not is_deleted
),
tl AS (
    select 
        label,
        _id as track_id,
        COUNT(distinct album_id) AS num_albums,
        MAX(COALESCE(popularity, 0)) AS track_popularity
    from hive.default.matvw_catalog_track
    cross join unnest(raw_recording_ids) as r(raw_recording_id)
    join lr USING(raw_recording_id)
    where not is_deleted
    group by 1, 2
)
-- select 
--     count(1) as num_tracks,
--     count_if(num_labels > 1) as num_2_lbl,
--     count_if(num_labels > 4) as num_5_lbl,
--     count_if(num_labels > 9) as num_10_lbl,
--     count_if(num_labels > 19) as num_20_lbl
-- from (
    select 
        track_id,
        count(1) as num_labels,
        array_agg(label) as labels
    from tl
    group by 1
    having count(1) > 20
    limit 100
-- )