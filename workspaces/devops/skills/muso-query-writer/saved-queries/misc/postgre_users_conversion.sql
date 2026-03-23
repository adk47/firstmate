/*
id: postgre_users_conversion
title: Postgre Users Conversion
athena_id: 99cb67bc-3fe9-42c8-add7-0f5154e18c81
primary_tag: misc
tags: [misc]
athena_database: production-quality-checks
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with _subs AS (
	select user_id,
		user_create_date,
		user_status,
		COALESCE(subscription_start, user_create_date) AS subscription_start_date,
		subscription_end IS NULL AS is_active,
		COALESCE(subscription_status, user_status) AS subscription_status
	from (
			select id as user_id,
				subscriptionstatus AS user_status,
				DATE(createdatdate) AS user_create_date,
				UPPER(
					CAST(
						json_extract(sub, '$.subscriptionStatus') AS VARCHAR
					)
				) AS subscription_status,
				from_unixtime(
					CAST(
						json_extract(sub, '$.subscriptionStart') AS BIGINT
					) / 1000
				) AS subscription_start,
				from_unixtime(
					CAST(json_extract(sub, '$.subscriptionEnd') AS BIGINT) / 1000
				) AS subscription_end,
				sub
			from "production-musomvp"."public_users"
				CROSS JOIN UNNEST(
					CONCAT(
						COALESCE(
							CAST(
								json_extract(
									appledata,
									'$.previousSubscriptions'
								) AS array(json)
							),
							ARRAY [ ]
						),
						COALESCE(
							CAST(
								json_extract(
									googledata,
									'$.previousSubscriptions'
								) AS array(json)
							),
							ARRAY [ ]
						),
						COALESCE(
							CAST(
								json_extract(
									stripedata,
									'$.previousSubscriptions'
								) AS array(json)
							),
							ARRAY [ ]
						),
						COALESCE(
							CAST(
								json_extract(
									paypaldata,
									'$.previousSubscriptions'
								) AS array(json)
							),
							ARRAY [ ]
						)
					)
				) AS s(sub)
		)
),
cncl AS (
	select DATE(subscription_start_date) AS period_day,
		count(distinct user_id) AS num_cancelled
	from _subs
	WHERE subscription_status LIKE '%CANCEL%'
	group by 1
),
resub AS (
	select date(last_paid) AS period_day,
		count(1) AS num_resubscribed
	from (
			select user_id,
				MAX(
					IF(
						subscription_status IN ('PRO', 'DID_RENEW', 'SUBSCRIBED', 'DID_CHANGE_RENEWAL_PREF')
						and user_status = 'PRO',
						subscription_start_date
					)
				) AS last_paid,
				MAX(
					IF(
						subscription_status LIKE '%EXPIRE%'
						OR subscription_status LIKE '%CANCEL%'
						OR subscription_status LIKE '%PAST%'
						OR subscription_status LIKE '%FAIL%'
						OR subscription_status LIKE '%SUSPEND%',
						subscription_start_date
					)
				) AS last_cancel
			from _subs
			group by 1
		)
	WHERE last_paid > last_cancel
	GROUP BY 1
),
usr as (
	select IF(
			period_day >= DATE('2022-07-18'),
			'Jul 18 - Jul 31',
			'Jul 4 - Jul 17'
		) AS period,
		SUM(num) AS num,
		SUM(trial) AS trial,
		SUM(num_pro) AS num_pro,
		SUM(num_cancelled) AS num_cancelled,
		SUM(num_resubscribed) AS num_resubscribed,
		MAX(period_day) AS max_date
	from (
			select DATE(createdatdate) AS period_day,
				count(1) AS num,
				count(subscriptionstatus) AS trial,
				COUNT_IF(subscriptionstatus IN ('PRO')) AS num_pro,
				MAX(createdatdate) AS max_date
			from "production-musomvp"."public_users"
			WHERE DATE(createdatdate) between DATE('2022-07-04') and DATE('2022-07-31')
			GROUP BY 1
		)
		LEFT JOIN cncl USING(period_day)
		LEFT JOIN resub USING(period_day)
	group by 1
)
select period,
	num AS "Users Registered",
	trial AS "Started Trial",
	num_pro AS "Pro Users",
	num_cancelled AS "Cancelled",
	num_resubscribed AS "Resubscribed"
from usr
order by max_date