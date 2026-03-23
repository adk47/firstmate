/*
id: top_shazamed_tracks
title: [Marketing] Top shazamed tracks
athena_id: 400b4af9-c7ae-4601-8e20-28fa5c48e726
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with t as (
select 
    track_id as _id,
    MAX(streams) as shazams
from "platform-industry-bi-prod".matvw_analytics_link
where source='shazam'
group by 1
)
select
    _id as track_id,
    title,
    array_join(transform(artists, a->a.name), ',') as artists,
    shazams
from "platform-industry-bi-prod".matvw_catalog_track 
join t USING(_id)
where not is_deleted and cardinality(artists) > 0
order by shazams desc 
limit 100