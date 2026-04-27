/*
id: export_tracks_with_stats_for_profile
title: [Sales] Export tracks with stats for profile
athena_id: 7a791426-e145-4db8-94d3-ac99f048410f
primary_tag: sales
tags: [sales]
athena_database: data-export-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with t as (
	select _id as track_id,
		title as track_title,
		array_join(transform(artists, a->a.name), ',') as artists,
		date(from_unixtime(release_timestamp / 1000)) as release_date,
		array_join(isrcs, ',') as isrcs,
		coalesce(popularity, 0) as track_popularity,
		array_distinct(transform(p.catalog_credits, c->c.child)) as credits,
		cardinality(profiles) as num_collabs,
		default_release.title as main_album_title,
		default_release.label as main_album_label
	from hive."platform-industry-bi-prod".matvw_catalog_track
		cross join unnest(profiles) as tp(p)
	where p.profile_id = 'e37a6853-05b5-4537-b8cf-ffcb57a595d5'
-- 		and cardinality(
-- 			filter(p.catalog_credits, cc->cc.parent = 'Songwriter')
-- 		) > 0
		and not is_deleted
),
-- ta as (
-- 	select track_id,
-- 		array_agg(distinct title) as albums
-- 	from "data-export-prod".album_track as t
-- 		left join "data-export-prod".album as a ON (t.album_id = a.id)
-- 	group by 1
-- ),
a as (
	select track_id,
		max_by(streams, date) as streams
-- 		,max_by(spotify_streams, date) as spotify_streams,
-- 		max_by(spotify_streams, date) - coalesce(
-- 			max_by(
-- 				spotify_streams,
-- 				if(
-- 					date(date) < current_date - interval '28' day,
-- 					date
-- 				)
-- 			),
-- 			0
-- 		) as spotify_streams_28d,
-- 		MAX(
-- 		    IF(	
-- 		        date(date)=DATE_ADD('day', -1, date_trunc('month', current_date)), 
-- 		        spotify_streams,
-- 		        0
-- 		    )
-- 		) - MAX(
-- 		    IF(	
-- 		        date(date)=DATE_ADD('day', -1, date_trunc('month', current_date) - interval '1' month), 
-- 		        spotify_streams,
-- 		        0
-- 		    )
-- 		) as spotify_streams_prev_1_month,
-- 		MAX(
-- 		    IF(	
-- 		        date(date)=DATE_ADD('day', -1, date_trunc('month', current_date) - interval '1' month),
-- 		        spotify_streams,
-- 		        0
-- 		    )
-- 		) - MAX(
-- 		    IF(	
-- 		        date(date)=DATE_ADD('day', -1, date_trunc('month', current_date) - interval '2' month),
-- 		        spotify_streams,
-- 		        0
-- 		    )
-- 		) as spotify_streams_prev_2_month,
-- 		MAX(
-- 		    IF(	
-- 		        date(date)=DATE_ADD('day', -1, date_trunc('month', current_date) - interval '2' month), 
-- 		        spotify_streams,
-- 		        0
-- 		    )
-- 		) - MAX(
-- 		    IF(	
-- 		        date(date)=DATE_ADD('day', -1, date_trunc('month', current_date) - interval '3' month), 
-- 		        spotify_streams,
-- 		        0
-- 		    )
-- 		) as spotify_streams_prev_3_month
	from "platform-stats-export-prod".public_track_daily
	group by 1
)
select *
from t
	left join a USING(track_id)
-- 	left join ta USING(track_id)
order by streams desc,
	track_popularity desc