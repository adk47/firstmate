/*
id: catalog_api_credits_collabs
title: [catalog] Catalog API credits/collabs
athena_id: c71bd001-9c78-493e-a351-baa5cbbdf06e
primary_tag: catalog
tags: [catalog]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

SELECT day >= date_format(date_add('day', -7, CURRENT_DATE), '%Y/%m/%d') AS after_change,
	IF(
		request_url LIKE '%/credits?%',
		'credits',
		'collabs'
	) AS request_type,
	count(1) AS number_requests,
	round(approx_percentile("target_processing_time", 0.50), 2) AS p50,
	round(approx_percentile("target_processing_time", 0.90), 2) AS p90,
	round(approx_percentile("target_processing_time", 0.99), 2) AS p99,
	round(approx_percentile("target_processing_time", 0.999), 2) AS p999
from "aws-admin"."alb_logs_v4"
where (
		day between date_format(date_add('day', -7, CURRENT_DATE), '%Y/%m/%d')
		and date_format(CURRENT_DATE, '%Y/%m/%d')
		OR day between date_format(date_add('day', -60, CURRENT_DATE), '%Y/%m/%d')
		and date_format(date_add('day', -53, CURRENT_DATE), '%Y/%m/%d')
	)
	and REGEXP_LIKE(
		"request_url",
		'^http(s)?:\/\/api-production.muso.ai(:443)?\/api\/(m|w)\/(v3|v4)\/(artist|profile)\/.*\/(credits|collab).*limit=5.*$'
	)
	and target_status_code = '200'
	and request_verb = 'GET'
group by 1, 2 
order by 2, 1