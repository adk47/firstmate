/*
id: credits_muso_ai_ips_to_block
title: [WAF] credits.muso.ai IPs to block
athena_id: 0a2a823e-c461-40c7-b138-baa1400d6e13
primary_tag: waf
tags: [waf]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    c_ip,
    count(1) as num
from "aws-admin".cloudfront_standard_logs 
where date >=current_date - interval '2' day
and cs_host = 'd1q4vlkztj70ds.cloudfront.net'
group by 1
order by 2 desc
limit 100