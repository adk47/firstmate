/*
id: mlc_works_recordings_vs_alternative_version_muso
title: MLC works recordings vs Alternative version Muso
athena_id: 5d112452-5f6b-4edc-af65-34c73fa4276e
primary_tag: misc
tags: [misc]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with 
mp as (
    select 'T0717217690' as iswc, '091e80ec-ab94-4366-bc59-9b96efc232b1' as _id, 'Bring Me To Life' as title
    union all
    select 'T0715144345' as iswc, '157ffeeb-f12d-4ee6-a3cf-cba86f07ea59' as _id, 'Hallelujah' as title
    union all
    select 'T9178198088' as iswc, '7d2bb43c-6b6f-450f-8541-e163c384530d' as _id, 'Hello' as title
),
_mlc as (
    select 
        iswc, 
        array_agg(isrc) AS mlc_isrcs
    from "platform-industry-mlc-bi-prod".works
    	join "platform-industry-mlc-bi-prod".worksrecordings USING(feedprovidersworkid)
    	join "platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
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
        isrcs,
        _id
    from "platform-industry-bi-prod".matvw_catalog_track
    cross join unnest(profiles) as p(pc)
    cross join unnest(pc.catalog_credits) as p(cc)
    where not is_deleted and cc.parent = 'Songwriter'
),
muso as (
    select distinct
        isrc,
        TRUE as is_muso,
        mp._id
    from pt as m 
    join mp ON(mp._id=m._id)
    join pt as s ON (m.profile_id=s.profile_id and starts_with(lower(s.title), lower(m.title)))
    cross join unnest(s.isrcs) as i(isrc)
)
select 
    title,
    COUNT_IF(is_muso is not null and mlc.iswc is not null) as in_both,
    COUNT_IF(is_muso is null and mlc.iswc is not null) as in_mlc_only,
    COUNT_IF(is_muso is not null and mlc.iswc is null) as in_muso,
    arbitrary(_id) as track_id
from mlc 
full outer join muso USING(_id, isrc)
join mp USING(_id)
group by 1