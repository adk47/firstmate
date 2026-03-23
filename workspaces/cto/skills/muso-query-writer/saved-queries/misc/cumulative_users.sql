/*
id: cumulative_users
title: Cumulative Users
athena_id: 389e72d8-d143-46b4-92dc-95ac7be7aec7
primary_tag: misc
tags: [misc]
athena_database: sandbox-oleg
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with cum AS (
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
select DATE(date_column) AS "date",
	-- CUMULATIVE
	count(1) AS cnt_total,
	COUNT_IF(last_subscription_status in ('PRO')) AS cnt_paid,
	COUNT_IF(last_subscription_status = 'CANCELLED') AS cnt_cncl,
	COUNT_IF(last_subscription_status = 'EXPIRED') AS cnt_expired,
	COUNT_IF(last_subscription_status = 'TRIAL') AS cnt_trial,
	-- DAILY
	count_if(status_changed) AS change_total,
	COUNT_IF(
		status_changed
		AND last_subscription_status IN ('PRO')
	) AS change_paid,
	COUNT_IF(
		status_changed
		AND last_subscription_status = 'CANCELLED'
	) AS change_cncl,
	COUNT_IF(
		status_changed
		AND last_subscription_status = 'EXPIRED'
	) AS change_expired,
	COUNT_IF(
		status_changed
		AND last_subscription_status = 'TRIAL'
	) AS change_trial,
	-- conversions 30 days rolling
	TRY(
		1.0 * SUM(
			COUNT_IF(
				status_changed
				AND last_subscription_status = 'TRIAL'
			)
		) OVER (
			ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
		) / SUM(
			COUNT_IF(DATE(date_column) = DATE(user_create_date))
		) OVER (
			ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
		)
	) AS trial_to_new,
	TRY(
		1.0 * SUM(
			COUNT_IF(
				status_changed
				AND last_subscription_status = 'PRO'
			)
		) OVER (
			ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
		) / SUM(
			COUNT_IF(
				status_changed
				AND last_subscription_status = 'TRIAL'
			)
		) OVER (
			ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
		)
	) AS pro_to_trial,
	TRY(
		1.0 * SUM(
			COUNT_IF(
				status_changed
				AND last_subscription_status = 'CANCELLED'
			)
		) OVER (
			ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
		) / SUM(
			COUNT_IF(
				status_changed
				AND last_subscription_status = 'PRO'
			)
		) OVER (
			ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
		)
	) AS cancel_to_pro,
	-- NEW 30 days rolling
	SUM(
		COUNT_IF(
			status_changed
			AND last_subscription_status = 'TRIAL'
		)
	) OVER (
		ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
	) AS trial_30d,
	SUM(
		COUNT_IF(
			status_changed
			AND last_subscription_status = 'PRO'
		)
	) OVER (
		ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
	) AS pro_30d,
	SUM(
		COUNT_IF(
			status_changed
			AND last_subscription_status = 'CANCELLED'
		)
	) OVER (
		ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
	) AS cancelled_30d,
	SUM(
		COUNT_IF(
			status_changed
			AND last_subscription_status = 'EXPIRED'
		)
	) OVER (
		ORDER BY DATE(date_column) ASC ROWS 29 PRECEDING
	) AS expired_30d,
	-- revenue
	SUM(reported_payment) AS revenue_30d
from cum
group by 1
order by 1 desc