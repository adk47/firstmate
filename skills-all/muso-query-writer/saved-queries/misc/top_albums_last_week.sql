/*
id: top_albums_last_week
title: [SMM] Top albums last week
athena_id: 62f73350-6a03-4706-b8f1-b35573ec431a
primary_tag: smm
tags: [smm]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select
    min(title) as title,
    array_join(array_agg(distinct p.name), ', ') as artists,
    min(date(from_unixtime(try(release_timestamp/1000)))) as release_date,
    max(r.popularity) as album_popularity,
    max(p.popularity) as top_artist_popularity, 
    'https://muso.ai/album/' || album_id as muso_url,
    MIN(r.images[1].url) as image_url
from hive."platform-industry-bi-prod".matvw_catalog_release as r
cross join unnest(artists) as ra(artist)
join hive."platform-industry-bi-prod".matvw_catalog_profile as p ON (p._id=artist.catalog_profile_id)
where 
    not r.is_deleted 
    and is_default_release
    and cardinality(r.images) > 0
    and from_unixtime(try(release_timestamp/1000)) between current_date - interval '7' day and current_date 
group by album_id
order by avg(p.popularity) desc, max(r.popularity) desc 
limit 50