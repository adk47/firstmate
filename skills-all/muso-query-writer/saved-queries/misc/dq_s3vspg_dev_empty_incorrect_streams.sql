/*
id: dq_s3vspg_dev_empty_incorrect_streams
title: DQ - S3vsPG - dev - Empty/incorrect streams
athena_id: e8afd3d9-6c47-4016-a5f6-f56983ffd038
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

WITH track2isrc AS (
	select distinct isrc,
		track.id AS trackid
	from "songstats-nonprod2".users_credits_tracks
		cross join unnest(tracks) AS t(track)
),
s3_tracks as (
	select trackid,
		date,
		TRUE as does_exist,
		MAX(TRY_CAST("streams_total" AS BIGINT)) AS streams_total,
		MAX(TRY_CAST("views_total" AS BIGINT)) AS views_total,
		MAX(TRY_CAST("shazams_total" AS BIGINT)) AS shazams_total
	FROM "songstats-nonprod2".users_tracks_stats
		JOIN track2isrc USING(isrc)
	WHERE date = '2022-02-10'
		and period = '1d'
	GROUp BY 1,
		2
),
pg_tracks as (
	select trackid,
		date,
		TRUE as does_exist,
		MAX(spotifystreams) + SUM("soundcloudstreams") AS streams_total,
		MAX("youtubeviews") + SUM("tiktokviews") AS views_total,
		MAX(shazams) AS shazams_total
	from "nonproduction-musomvp".public_track_stats
	WHERE date = '2022-02-10'
	GROUP BY 1,
		2
)
select 
    count(1) AS cnt,
    count_if(s3_streams > 0 and pg_streams > 0 and pg_streams <> s3_streams) AS cnt_non_0_streams_differ,
    count_if(s3_streams = 0 and pg_streams > 0) AS cnt_s3_empty
from (
		select trackid,
			s3_tracks.streams_total AS s3_streams,
			pg_tracks.streams_total AS pg_streams,
			100.0 *(
				s3_tracks.streams_total - pg_tracks.streams_total
			) / pg_tracks.streams_total AS diff
		from s3_tracks
			JOIN pg_tracks USING(date, trackid)
	)