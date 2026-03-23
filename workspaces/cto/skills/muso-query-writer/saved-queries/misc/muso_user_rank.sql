/*
id: muso_user_rank
title: [klaviyo] Muso User Rank
athena_id: df7996ba-6e87-4a4e-8c8d-2f5d47f01642
primary_tag: klaviyo
tags: [klaviyo]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with u AS (
select 
    t.email,
    arbitrary(s.seatid) as _id
from "platform-core-backend-export-prod".public_teams as t
join "platform-core-backend-export-prod".public_roster_seats AS s ON (t.id=s.teamid)
group by 1
having count(distinct s.seatid) = 1
)
select 
    email AS "Email Address",
    COALESCE(rank, 5) AS "Muso Rank"
from "platform-industry-bi-prod".matvw_catalog_profile as p 
join u USING (_id)