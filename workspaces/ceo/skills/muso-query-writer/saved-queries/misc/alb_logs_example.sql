/*
id: alb_logs_example
title: ALB logs example
athena_id: a6e7a44e-b96e-4ddd-b7b4-48ef0250dfec
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
-- SPLIT(SPLIT_PART(request_url, '/api/', 2), '/'), 
time,
request_url,
*
from aws_admin.alb_logs
where year = '2022'
	and month = '06'
-- 	and day = '04'
-- 	and time > '2022-04-04'
-- 	and request_url LIKE '%m/v3/analytics/759472c9-18e2-4786-8553-62e10b8981bb/catalogue%'
and request_url LIKE '%/m/%analytics%d6bdc694-24e2-48b6-b7b7-055af2a56abf%'
-- 	and target_status_code = '400' 
-- 	and request_verb = 'PUT'
-- group by 1
order by 1 desc