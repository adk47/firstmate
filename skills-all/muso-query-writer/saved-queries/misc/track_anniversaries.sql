/*
id: track_anniversaries
title: [SMM] Track Anniversaries
athena_id: 201da5eb-9405-4524-8323-6de21e98aebe
primary_tag: smm
tags: [smm]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with a as (
	select _id as track_id,
		date(from_unixtime(release_timestamp / 1000)) as release_date,
		popularity,
		title,
		array_join(transform(artists, a->a.name), ',') as artists,
		split_part(default_raw_recording_id, ':', 2) as spotify_id,
		year(current_date + interval '1' month) - year(date(from_unixtime(release_timestamp / 1000))) as years_anniversary
-- 		IF(
-- 			month(date(from_unixtime(release_timestamp / 1000))) = month(current_date),
-- 			year(current_date + interval '1' month) - year(date(from_unixtime(release_timestamp / 1000))),
-- 			year(current_date) - year(date(from_unixtime(release_timestamp / 1000)))
-- 		) as years_anniversary
	from hive."platform-industry-bi-prod".matvw_catalog_track
	where not is_deleted
		and popularity > 50
		and default_raw_recording_id like 'spotify:%'
		and month(date(from_unixtime(release_timestamp / 1000))) = month(current_date + interval '1' month)
-- 		and (
-- 			(
-- 				month(date(from_unixtime(release_timestamp / 1000))) = month(current_date)
-- 				and day(date(from_unixtime(release_timestamp / 1000))) >= day(current_date)
-- 				and year(current_date) - year(date(from_unixtime(release_timestamp / 1000))) in (1, 2, 3, 5, 10, 20, 30, 40, 50)
-- 			)
-- 			OR (
-- 				month(date(from_unixtime(release_timestamp / 1000))) = month(current_date + interval '1' month)
-- 				and day(date(from_unixtime(release_timestamp / 1000))) < day(current_date + interval '1' month)
-- 				and year(current_date + interval '1' month) - year(date(from_unixtime(release_timestamp / 1000))) in (1, 2, 3, 5, 10, 20, 30, 40, 50)
-- 			)
-- 		)
),
s as (
	select track_id,
		streams
	from "platform-stats-export-prod".public_track_daily
	where date = cast(current_date - interval '1' day as varchar)
)
select *
from (
		select 'https://muso.ai/track/' || track_id as muso_url,
			release_date,
			years_anniversary,
			title,
			artists,
			popularity,
			streams,
			row_number() over (
				partition by date_format(release_date, '%m/%d')
				order by popularity desc,
					streams desc
			) as day_rank,
			'https://open.spotify.com/track/' || spotify_id as spotify_url
		from a
			join s USING(track_id)
	)
where day_rank <= 20
order by date_format(release_date, '%m/%d'),
	day_rank
limit 1000