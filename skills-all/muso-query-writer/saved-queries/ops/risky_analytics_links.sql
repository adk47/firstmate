/*
id: risky_analytics_links
title: [Ops] Risky analytics links
athena_id: 0b0ca89a-09a2-48a5-8b1b-edebda5f7639
primary_tag: ops
tags: [ops]
athena_database: platform-stats-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- live, remix, cover, version, edit -> if not there 
with l as (
    select 
    	track_id,
    	external_id,
    	source,
    	name,
    	duration,
    	published_date,
    	url,
    	streams,
    	action_by
    from "platform-stats-export-prod".public_analytics_link
    where nullif(deleted_timestamp, '') is null
    	and nullif(merged_to_id, '') is null
    	and source = 'youtube'
    	and action_by not like '%system%'
    	and action_by not like '%platform_mlc_analytics_link%'
    	and streams > 10000
),
ts as (
    select 
        track_id,
        max_by(spotify_streams, date) as spotify_streams
    from "platform-stats-export-prod".public_track_daily 
    group by 1
)
select 
    (
        title_risk + streams_risk + artist_risk + duration_risk + date_risk
    ) * if(strpos(added_by, 'user:') > 0, 2, 1) as total_risk,
    name as link_title,
    title as track_title,
    artists as track_artists,
    link_streams,
    spotify_streams as track_spotify_streams,
    added_by,
    youtube_url,
    'https://credits.muso.ai/search/tracks?keyword=' || url_encode(name) as search_url,
    '' as CORRECT_TRACK_ID,
    '' as IS_NON_MUSIC_VIDEO
from (
    select 
        CASE 
            when strpos(
                regexp_replace(lower(name), '[^a-zA-Z0-9\s]', ''), 
                regexp_replace(lower(title), '[^a-zA-Z0-9\s]', '')
            ) > 0 then 0
            when strpos(
                translate(regexp_replace(lower(name), '[^a-zA-Z0-9\s]', ''), 'àáâãäåèéêëìíîïòóôõöùúûüýÿ', 'aaaaaaeeeeiiiiooooouuuuyy'),
                translate(regexp_replace(lower(title), '[^a-zA-Z0-9\s]', ''), 'àáâãäåèéêëìíîïòóôõöùúûüýÿ', 'aaaaaaeeeeiiiiooooouuuuyy')
            ) > 0 then 0
             
            when strpos(
                translate(regexp_replace(lower(name), '[^a-zA-Z0-9\s]', ''), 'àáâãäåèéêëìíîïòóôõöùúûüýÿ', 'aaaaaaeeeeiiiiooooouuuuyy'), 
                array_join(slice(split(translate(regexp_replace(lower(title), '[^a-zA-Z0-9\s]', ''), 'àáâãäåèéêëìíîïòóôõöùúûüýÿ', 'aaaaaaeeeeiiiiooooouuuuyy'), ' '), 1, 3), ' ')
            ) > 0 then 1
            else 5
        end as title_risk,
        case
            when spotify_streams > link_streams*2 then 0
            when spotify_streams > link_streams then 1
            when link_streams > spotify_streams*5 then 5
            when link_streams > spotify_streams*2 then 4
            when link_streams > spotify_streams then 3
            else 2
        end as streams_risk,
        CASE 
            when cardinality(
                filter(
                    artists,
                    a->strpos(lower(name), lower(a)) > 0
                )
            ) > 0 then 0
            else 1
        end as artist_risk,
        IF(ABS(link_duration - duration) > 20, 1, 0) as duration_risk,
        IF(date_diff('month', published_date, release_date) between -2 and 2, 0, 1) as date_risk,
        name,
        title,
        artists,
        link_streams,
        spotify_streams,
        published_date,
        release_date,
        link_duration,
        duration,
        action_by as added_by,
        'https://youtube.com/watch?v=' || external_id as youtube_url,
        'https://credits.muso.ai/track/' || track_id as muso_url,
        track_id
    from (
        select 
            t.title,
            l.name,
            filter(array_distinct(transform(t.artists, a->a.name) || transform(t.artists, a->a.raw_name)), n->n is not null) as artists,
            date(from_unixtime(t.release_timestamp / 1000)) as release_date,
            date(l.published_date) as published_date,
            t.duration,
            l.duration as link_duration,
            l.streams as link_streams,
            l.url,
            l.action_by,
            l.track_id,
            l.source,
            l.external_id
        from hive."platform-industry-bi-prod".matvw_catalog_track as t 
        join l on(l.track_id=t._id)
        where not is_deleted
    )
    left join ts USING(track_id)
)
where artist_risk > 0 and title_risk > 1 and streams_risk > 0
order by (title_risk + streams_risk + artist_risk + duration_risk + date_risk)*if(strpos(added_by, 'user:') > 0, 2, 1) desc, link_streams desc 
limit 1000

-- select * from parq_musicalworks limit 100

-- select * from (
-- select 'v2' as v, originaldataprovidername as source, count(1) as cnt_v2
-- from "platform-investigation-mlcv2".parq_resources  
-- group by 2
-- )
-- full outer join (
-- select 'v1' as v, originaldataprovidername as source, count(1) as cnt_v1
-- from hive."platform-industry-mlc-bi-prod".recordings
-- group by 2
-- ) using(source)
-- order by cnt_v1 desc

-- select *
-- from anghami_external 
-- limit 10