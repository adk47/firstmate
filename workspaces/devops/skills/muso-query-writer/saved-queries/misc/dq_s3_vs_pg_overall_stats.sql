/*
id: dq_s3_vs_pg_overall_stats
title: DQ - S3 vs PG - Overall stats
athena_id: f0d25968-7b84-4103-bea1-47c6aabcf031
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

WITH track2isrc AS (
    select distinct
        isrc,
        track.id AS trackid
    from "songstats-nonprod2".users_credits_tracks 
    cross join unnest(tracks) AS t(track)
),
s3_tracks as (
    select 
        trackid,
        date,
        TRUE as does_exist,
        MAX(TRY_CAST("streams_total" AS BIGINT)) AS streams_total,
        MAX(TRY_CAST("views_total" AS BIGINT)) AS views_total,
        MAX(TRY_CAST("shazams_total" AS BIGINT)) AS shazams_total
    FROM "songstats-nonprod2".users_tracks_stats 
    JOIN track2isrc USING(isrc)
    WHERE date = '2022-02-10' and period='1d'
    GROUp BY 1, 2
),
pg_tracks as (
    select 
        trackid,
        date,
        TRUE as does_exist,
        MAX(spotifystreams)+SUM("soundcloudstreams") AS streams_total,
        MAX("youtubeviews")+SUM("tiktokviews") AS views_total,
        MAX(shazams) AS shazams_total
    from "nonproduction-musomvp".public_track_stats
    WHERE date = '2022-02-10'
    GROUP BY 1,2
)
select 
    count(1) AS cnt_total, 
    count_if(s3_tracks.does_exist) AS cnt_new,
    count_if(pg_tracks.does_exist) AS cnt_old,
    count_if(pg_tracks.does_exist and s3_tracks.does_exist) AS cnt_intersect,
    sum(IF(s3_tracks.does_exist and pg_tracks.does_exist, s3_tracks.streams_total)) AS s3_streams_total,
    sum(IF(s3_tracks.does_exist and pg_tracks.does_exist, pg_tracks.streams_total)) AS pg_streams_total,
    sum(IF(s3_tracks.does_exist and pg_tracks.does_exist, s3_tracks.views_total)) AS s3_views_total,
    sum(IF(s3_tracks.does_exist and pg_tracks.does_exist, pg_tracks.views_total)) AS pg_views_total
from s3_tracks 
FULL OUTER 
JOIN pg_tracks USING(date, trackid)