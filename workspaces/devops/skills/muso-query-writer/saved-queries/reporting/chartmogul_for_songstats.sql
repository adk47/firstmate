/*
id: chartmogul_for_songstats
title: [Reporting] ChartMogul for Songstats
athena_id: 37af6ee1-df72-45d3-af6d-5bc02d1071db
primary_tag: reporting
tags: [reporting]
athena_database: chartmogul
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/


select 
    *,
    IF(status='Active', 'PRO', IF(trialed_this_month, 'TRIAL', 'CANCELLED')) AS muso_status
from (
    select 
        uuid, 
        MAX_BY(data_source_name, date) AS data_source_name, 
        MAX_BY(mrr, date) / 100 AS mrr, 
        MAX_BY(DATE(subscriber_since), date) AS subscriber_since,
        MAX_BY(status, date) AS status,
        SUM(IF(status = 'Lead', 1, 0)) > 0 AS trialed_this_month, 
        MAX_BY(plan_name, date) AS plan_name
    from "chartmogul"."dataset_customers"
    where date between '2022-12-01' and '2022-12-31'
    group by uuid
) where status NOT IN ('Cancelled') OR trialed_this_month

-- select * from "bi"."user_subscriptions"
-- order by coalesce(subscription_start, subscription_created) desc
-- limit 100

-- select * from "bi"."user_subscriptions"
-- where user_id = 34205

-- select * from "dataset_customers" limit 10


-- select 
--     *
-- from "dataset_customers" AS c
-- LEFT JOIN "dataset_activities" AS a ON (c.uuid=a.customer_uuid)
-- where c.date = '2022-12-31'
-- order by c.uuid, a.date desc

-- select uuid from "dataset_customers" group by 1 having max(date) < '2022-12-01'

-- select * from "dataset_activities"  limit 10

-- select * 
-- from "bi"."user_transactions" 
-- order by transaction_date desc
-- limit 100

-- select * 
-- from "production-musomvp"."public_payment_history"
-- order by transactiondate desc
-- limit 100
