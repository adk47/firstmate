/*
id: profiles_platform_wide
title: [Charts] Profiles Platform-wide
athena_id: fdc08f24-2a54-4de1-b7f5-b350ee747790
primary_tag: charts
tags: [charts]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    category,
    position_stream_1y as position,
    name,
    score_stream_1y as streams_2025, 
    'https://credits.muso.ai/profile/' || profile_id as muso_url
from "platform-industry-calc-prod".calc_credit_score_charts_entries_history 
where date ='2025-12-04' and position_stream_1y < 21
order by 1, 2

with ts as (
    select 
        track_id,
        streams
    from postgresql_industry.public.industry_data_processing_analytics_maintenance_daily_v2_track_stats_to_insert
),
c as (
    select distinct
        category,
        child_credit as child,
        parent_credit as parent,
        pt.profile_type
    from "platform-industry-db-industry-prod".dict_credit_category_rule
    cross join unnest(profile_type) as pt(profile_type)
    cross join unnest(coalesce(child, array['none'])) as c(child_credit)
    cross join unnest(coalesce(parent, array['none'])) as p(parent_credit)
),
pt as (
    select 
        distinct 
        category,
        p._id as profile_id,
        t._id as track_id
    from hive.default.matvw_catalog_track as t
    cross join unnest(profiles) as tp(profile)
    join hive.default.matvw_catalog_profile as p ON (p._id=profile.profile_id)
    cross join unnest(profile.catalog_credits) as pc(catalog_credit)
    join c ON (p.profile_type=c.profile_type and (catalog_credit.child=c.child or c.child='none' and c.parent=catalog_credit.parent))
    where not t.is_deleted and not p.is_deleted
)
select 
    category,
    position,
    streams,
    num_tracks,
    name,
    'https://credits.muso.ai/profile/' || profile_id as muso_url
from (
    select 
        category,
        profile_id,
        sum(streams) as streams,
        count(1) as num_tracks,
        row_number() over (partition by category order by SUM(streams) desc) as position
    from pt 
    join ts using(track_id)
    group by 1, 2
-- where profile_id = '86bd5f90-e94e-01c4-ff21-5f8b6bb6d308'
) as s
join hive.default.matvw_catalog_profile as p ON(profile_id=_id)
where position < 21
