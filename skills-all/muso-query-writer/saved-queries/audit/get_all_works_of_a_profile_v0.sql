/*
id: get_all_works_of_a_profile_v0
title: [Audit] Get all works of a profile v0
athena_id: 7bddadc2-fc66-403d-b456-3ff3ca749be5
primary_tag: audit
tags: [audit]
trino_catalog: hive
trino_schema: audit
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p as (
    select 
        m.feedprovidersworkid as mlc_work_id,
        array_agg(distinct pa.fullname) as represented_by 
    from hive."platform-industry-mlc-bi-prod".workrightshares as m
    join hive."platform-industry-mlc-bi-prod".workrightshares as p ON p.feedprovidersworkrightshareid = m.feedprovidersparentworkrightshareid
    join hive."platform-industry-mlc-bi-prod".parties as pa ON (m.feedproviderspartyid=pa.feedproviderspartyid)
    where 
        m.partyrole = 'OriginalPublisher' 
        and p.partyrole in ( 'ComposerLyricist', 'Composer', 'Lyricist', 'Arranger', 'SubLyricist', 'Adapter' )
        and p.feedproviderspartyid in (
            select 
                 cast(substr(rid, 5) as int) as rid
            from hive."platform-industry-bi-prod".matvw_catalog_profile 
            cross join unnest(raw_profile_ids) as r(rid)
            where _id = 'b299b6c9-0f5f-49ea-8a6a-636507ac097b' and rid like 'mlc:%'
        )
        group by 1
)
select 
    COALESCE(mlc_work_id, '[NO MLC WORK] ' || title) as mlc_work_id,
    min_by(title, length(title)) as title,
    min_by(artists, length(title)) as artists_from_one_track,
    count(1) as num_tracks,
    sum(track_popularity) as sum_popularity,
    arbitrary(mlc_work_id) is null as no_mlc_work,
    array_join(array_distinct(flatten(array_agg(represented_by))), ', ') as represented_by,
    'https://credits.muso.ai/track/' || min_by(track_id, length(title)) as muso_track_url,
    min_by(spotify_url, length(title)) as spotify_track_url
from hive.audit.audit_profile_track
cross join unnest(coalesce(split(nullif(mlc_codes, ''), ','), array[cast(NULL as varchar)])) as w (mlc_work_id)
left join p USING(mlc_work_id)
where profile_id = 'b299b6c9-0f5f-49ea-8a6a-636507ac097b'
group by 1
order by 5 desc