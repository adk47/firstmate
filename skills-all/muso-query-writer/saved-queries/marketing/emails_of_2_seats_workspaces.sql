/*
id: emails_of_2_seats_workspaces
title: [marketing] Emails of 2+ seats workspaces
athena_id: 4a6ad68f-30cf-4d8c-9aad-b2205215595c
primary_tag: marketing
tags: [marketing]
athena_database: nonproduction-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with sub AS (
    select 
        teamid,
        max_by(status, createdat) AS status,
        max_by(plan, createdat) AS plan,
        max_by(service, createdat) AS service
    from "production-musomvp".public_subscriptions
    where status = 'active'
    group by teamid
)
select 
    teamid,
    arbitrary(t.email) AS email,
    arbitrary(t.name) as name,
    arbitrary(sub.service) as subscription_service,
    arbitrary(sub.status) as subscription_status,
    arbitrary(sub.plan) as subscription_plan,
    COUNT(distinct p._id) AS num_active_seats,
    SUM(p.credits_count) AS all_seats_credits_count,
    MAX_BY(p._id, p.popularity) AS top_profile_id,
    MAX_BY(p.name, p.popularity) AS top_profile_name,
    MAX(p.popularity) AS top_profile_popularity,
    array_agg(distinct s.seatid) AS seat_ids
from "production-musomvp".public_teams as t
join "production-musomvp".public_roster_seats AS s ON(teamid=t.id)
join "platform-industry-bi-prod".matvw_catalog_profile as p ON (s.seatid=p._id)
join sub USING(teamid)
where s.status='active' and nullif(t.email, '') is not null and not p.is_deleted
group by 1
having COUNT(distinct p._id) > 2
order by top_profile_popularity desc