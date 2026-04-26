/*
id: luminate_users_list
title: Luminate Users List
athena_id: e78b2fab-73e9-4a2b-a0a5-7c138581fa9b
primary_tag: misc
tags: [misc]
trino_catalog: postgresql_analytics
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with um AS (
	select date_trunc('month', date_column) as month,
		user_id,
		ARBITRARY(user_email) AS user_email,
		MAX(reported_payment) AS rev,
		LAG(MAX(reported_payment)) OVER (
			partition by user_id
			ORDER BY MAX(date_column)
		) AS prev_rev,
		MAX_BY(last_subscription_status, date_column) AS status,
		MIN(
			IF(
				MAX(reported_payment) > 0,
				MIN(date_column),
				NULL
			)
		) OVER (PARTITION BY user_id) AS min_payment_date,
		MAX(
			IF(
				MAX(reported_payment) > 0,
				MAX(date_column),
				NULL
			)
		) OVER (PARTITION BY user_id) AS max_payment_date
	from "bi"."user_daily_stats"
	group by 1,
		2
)
select user_id,
	ARBITRARY(user_email) AS email,
	SUM(rev) AS clv,
	MAX(IF(month = '2021-07', rev)) AS "Jul-21",
	MAX(IF(month = '2021-08', rev)) AS "Aug-21",
	MAX(IF(month = '2021-08', rev)) AS "Sep-21",
	MAX(IF(month = '2021-10', rev)) AS "Oct-21",
	MAX(IF(month = '2021-11', rev)) AS "Nov-21",
	MAX(IF(month = '2021-12', rev)) AS "Dec-21",
	MAX(IF(month = '2022-01', rev)) AS "Jan-22",
	MAX(IF(month = '2022-02', rev)) AS "Feb-22",
	MAX(IF(month = '2022-03', rev)) AS "Mar-22",
	MAX(IF(month = '2022-04', rev)) AS "Apr-22",
	MAX(IF(month = '2022-05', rev)) AS "May-22",
	MAX(IF(month = '2022-06', rev)) AS "Jun-22",
	MAX(IF(month = '2022-07', rev)) AS "Jul-22"
from (
		select SUBSTR(CAST(month AS VARCHAR), 1, 7) as month,
			user_id,
			user_email,
			rev
		from um
	)
group by user_id
HAVING sum(rev) > 0