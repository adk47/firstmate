/*
id: all_plaques_purchasers
title: [Plaques] All plaques purchasers
athena_id: fdaa5e0f-ac8a-4f97-a60f-793c1e1d2757
primary_tag: plaques
tags: [plaques]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pu as (select distinct userid as id
from "platform-core-backend-export-prod".public_orders
where status in ('PAID', 'SHIPPED', 'PROCESSING')
)
select distinct
    email
from "platform-core-backend-export-prod".public_users
join pu USING(id)