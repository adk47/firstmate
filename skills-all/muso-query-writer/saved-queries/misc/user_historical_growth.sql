/*
id: user_historical_growth
title: [Finance] User historical growth
athena_id: 99b52fdc-4541-4a96-9633-8d29e4a5df51
primary_tag: finance
tags: [finance]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select u.id AS user_id,
                u.email,
                u.fullname AS user_name,
                u.createdat AS user_created_date,
                su.status AS user_subscription_status,
                s.status AS seat_status,
                s.seatid AS profile_id,
                p.name AS profile_name,
                p.profile_type,
                p.credits_count,
                p.common_credits,
                p.popularity AS profile_popularity,
                teamid,
                defaultteamid,
                teamid <> defaultteamid AS is_b2b_workspace
            FROM postgresql_core.public."public_users" AS u
                left join postgresql_core.public."public_team_users" AS tu ON (u.id = userid)
                left join postgresql_core.public."public_subscriptions" AS su USING (teamid)
                left join postgresql_core.public."public_roster_seats" AS s USING (teamid)
                left join hive."platform-industry-bi-prod"."matvw_catalog_profile" AS p ON (s.seatid = p._id)
            where date_diff(
                    'day',
                    CAST(SUBSTR(u.createdat, 1, 10) AS date),
                    current_date
                ) < 7
            order by u.createdat desc
            
select *
from postgresql_core.public."public_subscriptions"
order by createdat asc
limit 10

select 
    month,
    num_new,
    sum(num_new) over (order by month) as num_users,
    num_active as num_new_currently_active,
    sum(num_active) over (order by month) as num_currently_active
from (
    select 
        date_trunc('month', date(substr(u.createdat, 1, 10))) as month,
        count(distinct u.id) as num_new,
        count(distinct IF(su.status='active', u.id)) as num_active
    from postgresql_core.public."public_users" as u
    left join postgresql_core.public."public_team_users" AS tu ON (u.id = userid)
    left join postgresql_core.public."public_subscriptions" AS su USING (teamid)
    group by 1
)
order by 1

select 
    *
from (
    select 
        day,
        num_new,
        sum(num_new) over (order by day) as num_users,
        num_active as num_new_currently_active,
        sum(num_active) over (order by day) as num_currently_active
    from (
        select 
            date(substr(u.createdat, 1, 10)) as day,
            count(distinct u.id) as num_new,
            count(distinct IF(su.status='active', u.id)) as num_active
        from postgresql_core.public."public_users" as u
        left join postgresql_core.public."public_team_users" AS tu ON (u.id = userid)
        left join postgresql_core.public."public_subscriptions" AS su USING (teamid)
        group by 1
    )
)
where day > date('2025-11-14')
order by 1