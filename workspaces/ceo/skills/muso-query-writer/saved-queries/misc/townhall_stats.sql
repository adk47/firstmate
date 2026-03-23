/*
id: townhall_stats
title: Townhall Stats
athena_id: 60e9db61-8b11-4f87-91dc-824278a55ffb
primary_tag: misc
tags: [misc]
athena_database: nonproduction-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with period_dates AS (
	select DATE('2022-08-31') AS date_prev_end,
		DATE('2022-09-30') AS date_cur_end
),
cum AS (
	select *,
		last_subscription_status IS NOT NULL
		and (
			prev_subscription_status IS NULL
			OR last_subscription_status <> prev_subscription_status
		) AS status_changed
	from (
			select *,
				LAG(last_subscription_status) OVER (
					partition by user_id
					ORDER BY date_column
				) AS prev_subscription_status
			from "bi"."user_daily_stats"
		)
)
select is_cur,
	count_if(is_new) AS "Users Registered",
	count_if(is_trial) AS "Started Trial",
	count_if(is_new AND is_pro) AS "Subscribed",
	count_if(is_new AND is_cncl) AS "Cancelled"
from (
		select DATE(date_column) > date_prev_end AS "is_cur",
			user_id,
			-- CUMULATIVE
			COUNT_IF(
				DATE_DIFF(
					'day',
					DATE(user_create_date),
					DATE(date_column)
				) < 30
			) > 0 AS is_new,
			COUNT_IF(day_subscription_status = 'PRO') > 0 AS is_pro,
			COUNT_IF(day_subscription_status = 'CANCELLED') > 0 AS is_cncl,
			COUNT_IF(day_subscription_status = 'EXPIRED') > 0 AS is_expired,
			COUNT_IF(day_subscription_status = 'TRIAL') > 0 AS is_trial
		from cum
			cross join period_dates
		WHERE DATE(date_column) BETWEEN DATE_ADD('day', -29, date_prev_end) and date_cur_end
		group by 1,
			2
	)
group by 1
order by 1 desc