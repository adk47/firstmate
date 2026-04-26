/*
id: usage
title: [NFC] Usage
athena_id: 177964a8-3fef-4c06-ac06-04d588b18aab
primary_tag: nfc
tags: [nfc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with r AS (
	select split_part(request_url, '/', 5) AS alias,
		count(distinct day) as days_used
	from "aws-admin".alb_logs_v4
	where day > '2023/09/01'
		and request_url like 'https://api-production.muso.ai:443/p/%'
	group by 1
)
select count(1) AS num,
	count_if(days_used > 0) AS num_used,
	count_if(days_used > 1) AS num_used_2_days
from "production-musomvp".public_nfc_card
	left join r USING(alias)