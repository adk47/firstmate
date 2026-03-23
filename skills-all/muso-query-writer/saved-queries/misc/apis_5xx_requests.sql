/*
id: apis_5xx_requests
title: APIs - 5xx requests
athena_id: af0dc69e-4bfd-4602-a59b-a419042b557e
primary_tag: misc
tags: [misc]
athena_database: aws-admin
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with subset AS (
select request_url, time, target_status_code from "aws-admin".alb_logs 
limit 100000
)
select 
    "request_url", 
    target_status_code,
    count(1) AS num_requests 
from subset
where time > '2021-02-15'  and TRY_CAST(target_status_code AS INT) >= 500
group by 1,2
order by 3 desc