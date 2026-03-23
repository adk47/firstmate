/*
id: dq_s3_vs_pg_overall_stats
title: DQ - S3 vs PG - Overall stats
athena_id: e1eee243-8adb-42ed-8efd-d75c019e3d43
primary_tag: misc
tags: [misc]
athena_database: nonproduction-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/


select 
    's3' AS source,
    COUNT(1) AS cnt_user_tracks,
    sum(TRY_CAST("streams_total" AS BIGINT)) AS streams_total,
    sum(TRY_CAST("views_total" AS BIGINT)) AS views_total,
    sum(TRY_CAST("shazams_total" AS BIGINT)) AS shazams_total
from "songstats-nonprod2".users_tracks_stats 
where import_date='2022-02-14'

union all 
select 
    'pg' AS source,
    COUNT(1) AS cnt_user_tracks,
    sum(spotifystreams)+SUM("soundcloudstreams") AS streams_total,
    sum("youtubeviews")+SUM("tiktokviews") AS views_total,
    sum(shazams) AS shazams_total
from "nonproduction-musomvp".public_track_stats
-- where import_date='2022-02-14'