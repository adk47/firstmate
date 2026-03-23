/*
id: postgre_users_conversion
title: Postgre Users Conversion
athena_id: 9f61774d-9f17-478b-8e3a-1d31a90c5091
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr as (
	select 
	    IF(DATE(createdatdate) >= DATE('2022-03-11'), 'Mar 15 - Mar 27', 'Mar 6 - Mar 13') AS period,
		count(1) AS num,
		count(subscriptionstatus) AS trial,
		COUNT_IF(subscriptionstatus IN ('PRO', 'CANCELLED')) AS num_was_pro,
		COUNT_IF(subscriptionstatus IN ('PRO')) AS num_still_pro,
		MAX(createdatdate) AS max_date
	from "production-musomvp"."public_users"
	WHERE DATE(createdatdate) between DATE('2022-02-25') and DATE('2022-03-24')
	GROUP BY 1
)
select period,
    num AS "Users Registered",
    trial AS "Started Trial",
    num_was_pro AS "Pro Users",
    num_still_pro AS "Still Pro",
	100.0 * trial / num AS signup2trial,
	100.0 * num_was_pro / trial as trial2pro,
	100.0 * num_still_pro / num_was_pro as retention
from usr
order by max_date