/*
id: churn_cancelled_on_muso_by_plan_and_month
title: [AdHoc] Churn - cancelled on muso by plan and month
athena_id: 5ae3f39c-de7b-4c65-96e9-7134fe6b5eae
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    date_trunc('month', last_updated),
    plan,
    count(1) as num_subscriptions
from (
select
    service,
    plan,
     from_unixtime(try_cast(json_extract_scalar(
        details,
        '$.created'
    ) as bigint)) as created,
     from_unixtime(try_cast(json_extract_scalar(
        details,
        '$.periodStart'
    ) as bigint) / 1000) as period_start,
     from_unixtime(try_cast(json_extract_scalar(
        details,
        '$.expiresAt'
    ) as bigint) / 1000) as expires_at,
    date(substr(updatedat, 1, 10)) as last_updated
from "platform-core-backend-export-prod".public_subscriptions 
where status = 'cancelled' and plan <> 'vip'
)
where date_diff('day', period_start, expires_at) > 14
group by 1, 2 