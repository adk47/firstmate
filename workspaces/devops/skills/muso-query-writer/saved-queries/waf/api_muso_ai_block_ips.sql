/*
id: api_muso_ai_block_ips
title: [WAF] api.muso.ai block IPs
athena_id: e2d4f612-af9d-4a8f-bf69-24bb82fc31d6
primary_tag: waf
tags: [waf]
athena_database: aws-admin
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    client_ip,
    count(1) as num
from "aws-admin".alb_logs_core_prod_api_v2 
where 
    day >=date_format(current_date - interval '2' day, '%Y/%m/%d')
    and request_url like '%api.muso.ai%'
    and request_url not like '%/api/c/%'
group by 1
order by 2 desc
limit 100