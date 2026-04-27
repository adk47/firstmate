/*
id: muso_alternatives_not_in_mlc
title: Muso Alternatives not in MLC
athena_id: b915c82c-21c9-49be-b3ff-7c3a5ac4e6f2
primary_tag: misc
tags: [misc]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with 
mp as (
    select 'T0717217690' as iswc, '091e80ec-ab94-4366-bc59-9b96efc232b1' as _id, 'Bring Me To Life' as title
),
_mlc as (
    select 
        iswc, 
        array_agg(isrc) AS mlc_isrcs
    from hive."platform-industry-mlc-bi-prod".works
    	join hive."platform-industry-mlc-bi-prod".worksrecordings USING(feedprovidersworkid)
    	join hive."platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
    	group by 1 
    	having count(1) > 1
),
mlc as (
    select 
    distinct iswc, isrc, _id
    from _mlc 
    join mp USING(iswc)
    cross join unnest(mlc_isrcs) as i(isrc)
),
pt as (
    select 
        pc.profile_id,
        title,
        array_join(transform(artists, a->a.name), ', ') as artists,
        isrcs,
        _id,
        popularity
    from hive."platform-industry-bi-prod".matvw_catalog_track
    cross join unnest(profiles) as p(pc)
    cross join unnest(pc.catalog_credits) as p(cc)
    where not is_deleted and cc.parent = 'Songwriter'
),
muso as (
    select
        isrc,
        TRUE as is_muso,
        mp._id,
        s.title,
        s.artists,
        s._id as track_id,
        s.popularity
    from pt as m 
    join mp ON(mp._id=m._id)
    join pt as s ON (m.profile_id=s.profile_id and starts_with(lower(s.title), lower(m.title)))
    cross join unnest(s.isrcs) as i(isrc)
)
select distinct
    muso.track_id,
    muso.title,
    muso.artists,
    muso.popularity,
    isrc
from mlc 
full outer join muso USING(_id, isrc)
join mp USING(_id)
where is_muso is not null and mlc.iswc is null