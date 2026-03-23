/*
id: market_penetration
title: [Product] Market penetration
athena_id: 30a64804-8161-4985-8840-b13006a6229e
primary_tag: product
tags: [product]
athena_database: platform-core-backend-export-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with p as (
    select 
        *,
        row_number() over (partition by is_company order by popularity desc, credits_count desc, profile_id) as num_pop
    from (
        select
            _id as profile_id,
            profile_type='organization' as is_company,
            coalesce(popularity, 0) as popularity,
            coalesce(credits_count, 0) as credits_count
        from "platform-industry-bi-prod".matvw_catalog_profile
        where not is_deleted and profile_type in ('organization', 'artist', 'professional')
    )
),
s as (
    select 
        profile_id,
        IF(
            length(stream_stats) > 2, 
            TRY(CAST(reverse(
                split_part(
                    reverse(
                        replace(stream_stats, ']','')
                    ), 
                    ',',
                    1
                )
            ) as BIGINT)),
            0
        ) as streams
    from "platform-industry-calc-prod".calc_analytics_industry_stat_cube_profile_history 
    where date = '2025-09-10'
),
-- st as (
--     select 
--         profile_id,
--         sum(streams) as streams
--     from "platform-stats-export-prod".public_track_daily 
--     join "platform-stats-export-prod".public_profile_track USING(track_id)
--     where date = '2025-09-10'
-- ),
c as (
    select 
        distinct profileid as profile_id, TRUE as is_claimed
    from "platform-core-backend-export-prod".public_claiming 
    where status = 'processed'
),
r as (
    select 
        distinct seatid as profile_id, TRUE as in_roster
    from "platform-core-backend-export-prod".public_roster_seats
)
select 
    is_company,
    case 
        when num_pop <=2000 then '1. Superstars'
        when num_pop <=202000 then '2. Mainstream'
        else '3. Emerging'
    end as popularity,
    count(1) as num,
    cast(floor(avg(streams)) as bigint) as avg_streams,
    1.0 * count_if(is_claimed) / count(1) as pct_claimed,
    1.0 * count_if(in_roster) / count(1) as pct_in_roster
from p 
left join c USING(profile_id)
left join r USING(profile_id)
left join s USING(profile_id)
group by 1, 2
order by 1, 2
