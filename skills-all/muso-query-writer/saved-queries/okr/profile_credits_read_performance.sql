/*
id: profile_credits_read_performance
title: [OKR] Profile Credits Read Performance
athena_id: 9616384e-5654-43cf-91ba-e991bf77950f
primary_tag: okr
tags: [okr]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

SELECT count(1) AS number_requests,
	approx_percentile("target_processing_time", 0.50) AS p50,
	approx_percentile("target_processing_time", 0.90) AS p90,
	approx_percentile("target_processing_time", 0.99) AS p99,
	approx_percentile("target_processing_time", 0.999) AS p999
from "aws-admin"."alb_logs_v4"
where day between date_format(date_add('day', -7, CURRENT_DATE), '%Y/%m/%d')
	and date_format(CURRENT_DATE, '%Y/%m/%d')
	and REGEXP_LIKE(
		"request_url",
		'^https:\/\/api-production.muso.ai:443\/api\/(m|w)\/(v3|v4)\/(artist|profile)\/.*\/credits.*limit=5.*$'
	)
	and target_status_code = '200'
	and request_verb = 'GET'