/*
id: alb_errors_by_domain
title: ALB Errors by domain
athena_id: 4864ab98-f9a1-400c-9156-f9bddf40ff59
primary_tag: misc
tags: [misc]
athena_database: aws_admin
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    SPLIT_PART(request_url, '/',3) AS domain,
    -- SUBSTR(request_url, 1, 30),
    elb_status_code,
    count(1) AS num_req
from "aws_admin".alb_logs
where "year" = '2022'
	and "month" = '08'
	and CAST(day AS INT) = 29
	and elb_status_code >= 500
	group by 1, 2
order by 3 desc
-- limit 100