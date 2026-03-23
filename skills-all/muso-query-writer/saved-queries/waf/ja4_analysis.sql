/*
id: ja4_analysis
title: [waf] Ja4 analysis
athena_id: 723dd4a9-47a4-4a66-924a-383bbca90b03
primary_tag: waf
tags: [waf]
athena_database: aws-admin
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select
    ja4,
    sum(req_allow) as req_allow,
    100 * sum(req_allow) / sum(req) as pct_allow,
    sum(req) as req,
    count(1) as num_ips,
    array_agg(ip ) filter (where iprank < 5) as ips
from (
    select 
        ja4fingerprint as ja4,
        httprequest.clientip as ip,
        count(1) as req,
        count_if(action = 'ALLOW') as req_allow,
        row_number() over (partition by ja4fingerprint order by count_if(action = 'ALLOW') desc) as iprank
    from waf_main
    where 
        log_time > date_format(current_date - interval '1' day, '%Y/%m/%d')
    group by 1, 2 
)
group by 1
order by 2 desc 
limit 100
-- https://ja4db.com/api/read/?ja4_fingerprint=t13d1517h2_8daaf6152771_b0da82dd1658

select 
    log_time,
    count(1) as req,
    count_if(action = 'ALLOW') as req_allow
from waf_main
where 
    log_time between '2025/11/10' and  '2025/11/13'
    and ja4fingerprint = 't13d1516h2_8daaf6152771_d8a2da3f94cd'
group by 1
order by 1 desc

