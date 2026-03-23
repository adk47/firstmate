/*
id: luminate_timeline_aug
title: Luminate Timeline Aug
athena_id: 0cfb9804-2a1a-42f2-b87a-436729a38294
primary_tag: misc
tags: [misc]
athena_database: bi
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
select month,
	COALESCE(
		LAG(month_rev) OVER(
			order by month
		),
		0
	) AS "Opening",
	new_rev AS "New - Customers $ Value",
	GREATEST(
		LAG(month_rev) OVER(
			order by month
		) + new_rev - month_rev,
		0
	) AS "Lost - Customers $ Value",
	upgrade_rev AS "Upgrade Value",
	downgrade_rev AS "Downgrade Value",
	month_rev AS "End of Period",
	-- USERS
	COALESCE(
		LAG(usr) OVER(
			order by month
		),
		0
	) AS "Opening",
	new_usr AS "New",
	lost_usr AS "Lost",
	upgrade_usr AS "Upgrades",
	downgrade_usr AS "Contraction",
	usr AS "End of Period"
from (
		select SUBSTR(CAST(month AS VARCHAR), 1, 7) as month,
			ROUND(SUM(rev)) AS month_rev,
			ROUND(SUM(IF(COALESCE(prev_rev, 0) = 0, rev, NULL))) as new_rev,
			ROUND(
				SUM(
					IF(
						rev > 0
						and prev_rev > rev,
						prev_rev - rev,
						0
					)
				)
			) AS downgrade_rev,
			ROUND(
				SUM(
					IF(
						prev_rev > 0
						and prev_rev < rev,
						rev - prev_rev,
						0
					)
				)
			) AS upgrade_rev,
			count_if(rev > 0) AS usr,
			count_if(
				rev > 0
				and COALESCE(prev_rev, 0) = 0
			) AS new_usr,
			count_if(
				prev_rev > 0
				and COALESCE(rev, 0) = 0
			) AS lost_usr,
			count_if(
				prev_rev > 0
				and prev_rev < rev
			) AS upgrade_usr,
			count_if(
				rev > 0
				and prev_rev > rev
			) AS downgrade_usr
		from um
		where month between DATE('2021-06-01') and DATE('2022-08-01')
		group by 1
	)
order by 1