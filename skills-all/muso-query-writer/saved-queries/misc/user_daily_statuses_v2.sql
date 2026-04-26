/*
id: user_daily_statuses_v2
title: User Daily Statuses v2
athena_id: 67386d82-6ac6-4190-b1fa-718e85baec34
primary_tag: misc
tags: [misc]
trino_catalog: postgresql_analytics
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select date_column,
	last_status,
	count(1) AS num_usr
from "bi"."user_daily_status"
where CAST(DATE(date_column) AS VARCHAR) in (
		'2022-08-10',
		'2022-08-01',
		'2022-07-01',
		'2022-06-01'
	)
group by 1,
	2
order by DATE(date_column) desc,
	last_status