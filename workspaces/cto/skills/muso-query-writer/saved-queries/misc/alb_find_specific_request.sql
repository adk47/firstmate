/*
id: alb_find_specific_request
title: ALB - Find specific request
athena_id: 91719f3d-04ae-4322-8f03-b291f6afb189
primary_tag: misc
tags: [misc]
athena_database: aws_admin
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with subset AS (
	select request_url,
		time,
		sent_bytes,
		"target_processing_time",
		target_status_code,
		"request_verb",
		user_agent
	from aws_admin.alb_logs
	where year = '2022' and month = '02'
)
select time,
	"request_url",
	target_processing_time,
	target_status_code,
	request_verb,
	sent_bytes,
	user_agent
from subset
where time > '2022-02-01'
	and request_url LIKE '%profile%'
	and request_verb = 'PUT'
order by TRY_CAST(target_processing_time AS DOUBLE) desc