/*
id: investigation
title: [WAF] Investigation
athena_id: 4db6ad9f-cc00-446e-81e6-1b4c2a575b39
primary_tag: waf
tags: [waf]
athena_database: platform-qobuz-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select * from alb_logs_core_prod_api_v2 
where day between '2025/06/01' and '2025/06/02' 
-- and client_ip like '47.%'
and user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0'
order by time desc
limit 100


select 
    case 
        when lower(cs_user_agent) like '%googlebot%' then 'Google Bot'
        when lower(cs_user_agent) like '%amazonbot%' then 'Amazon Bot'
        when lower(cs_user_agent) like '%applebot%' then 'Apple Bot'
        when lower(cs_user_agent) like '%bot%' then 'Other Bot'
        else 'Other' end as ua,
        count_if(month='05') as num_prev,
        count_if(month='06') as num_cur,
        100 * count_if(month='06') / count_if(month='05') - 100 as pct_increase
from cfv2_cloudfrontv2
where partition_0 = 'credits.muso.ai' and year = '2025' and month in ('06', '05') and if(month='05', day > '29', day < '03')
-- and from_unixtime(cast(timestamp as bigint)) > date('2025-05-')
group by 1
order by 3 desc


select
    cs_user_agent,
    count(1)
from cfv2_cloudfrontv2
where partition_0 = 'credits.muso.ai' and year = '2025' and month in ('09') 
-- and day in ('01', '02')
and lower(cs_user_agent) not like '%bot%'
group by 1 
order by 2 desc 
limit 100

-- Mozilla/5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20AppleWebKit/537.36%20(KHTML,%20like%20Gecko)%20Chrome/129.0.0.0%20Safari/537.36
-- Mozilla/5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20AppleWebKit/537.36%20(KHTML,%20like%20Gecko)%20Chrome/114.0.0.0%20Safari/537.36%20Edg/114.0.1823.43
-- Mozilla/5.0%20(Windows%20NT%206.1;%20Win64;%20x64)%20AppleWebKit/537.36%20(KHTML,%20like%20Gecko)%20Chrome/126.0.6478.114%20Safari/537.36


select
    split_part(c_ip, '.',1) || '.' || split_part(c_ip, '.',2) as ip_pfx,
    count(1) as cnt,
    count(distinct c_ip) as cnt_ips,
    arbitrary(c_ip) as sample_ip,
    array_agg(distinct c_ip) as ips
from "aws-admin".cfv2_cloudfrontv2
where partition_0 = 'credits.muso.ai' and year = '2025' and month in ('09') 
-- and day in ('01', '02')
-- and lower(cs_user_agent) like '%win64%'
-- and lower(cs_user_agent) like '%20x64%'
and cs_user_agent = 'Mozilla/5.0%20(Windows%20NT%206.1;%20Win64;%20x64)%20AppleWebKit/537.36%20(KHTML,%20like%20Gecko)%20Chrome/126.0.6478.114%20Safari/537.36'
group by 1 
order by 2 desc 
limit 100

select * 
from "aws-admin".cfv2_cloudfrontv2
where partition_0 = 'credits.muso.ai' and year = '2025' and month in ('06') and day in ('01', '02')
and c_ip = '113.211.120.111'

select 
    ja4fingerprint,
    count(1) as cnt_all,
    100 * count_if(action = 'ALLOW') / count(1) as pct_allowed,
    arbitrary(httprequest.clientip) as random_ip
from "aws-admin"."waf_main" 
where log_time between '2025/09/01/' and '2025/09/10/'
group by 1
order by 2 desc
limit 100


