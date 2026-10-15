/*
id: muso_user_rank
title: [klaviyo] Muso User Rank
athena_id: df7996ba-6e87-4a4e-8c8d-2f5d47f01642
primary_tag: klaviyo
tags: [klaviyo]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- STACK SWAP (Oct 2026): this audience used to be uploaded to Klaviyo. Klaviyo is being retired; marketing
-- audiences go to Listmonk (skill muso-email) from the marketing cutover (~28 Oct). The SQL is unchanged;
-- only the destination moves, and the upload is a human step (Aaron / Nick).
with u AS (
select 
    t.email,
    arbitrary(s.seatid) as _id
from postgresql_core.public.teams as t
join postgresql_core.public.roster_seats AS s ON (t.id=s.teamid)
group by 1
having count(distinct s.seatid) = 1
)
select 
    email AS "Email Address",
    COALESCE(rank, 5) AS "Muso Rank"
from hive."platform-industry-bi-prod".matvw_catalog_profile as p 
join u USING (_id)