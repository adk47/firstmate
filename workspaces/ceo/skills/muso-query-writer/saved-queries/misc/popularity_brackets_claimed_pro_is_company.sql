/*
id: popularity_brackets_claimed_pro_is_company
title: [Investors] Popularity brackets (claimed, pro, is_company)
athena_id: f50f33b1-245e-40c8-a3f6-bbc1db284316
primary_tag: investors
tags: [investors]
athena_database: platform-qobuz-bi-prod
description: No description provided
status: one_off
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
c as (
    select 
        distinct profileid as profile_id, TRUE as is_claimed
    from "platform-core-backend-export-prod".public_claiming 
    where status = 'processed'
),
r as (
    select 
        distinct seatid as profile_id, TRUE as in_roster, status ='active' as is_paid
    from "platform-core-backend-export-prod".public_roster_seats
)
select 
    is_company,
    IF(
        popularity=0, 
        '0', 
        cast((popularity-1) / 10 * 10 + 1 as varchar) || '-' || cast((popularity-1) / 10 * 10 + 10 as varchar)
    ) as popularity_bracket,
    count_if(is_paid) as num_pro,
    count_if(is_claimed) as num_claimed,
    count_if(is_claimed AND is_paid) as num_pro_claimed,
    count(1) as num_total
from p 
left join c USING(profile_id)
left join r USING(profile_id)
group by 1, 2
order by 1, 2
