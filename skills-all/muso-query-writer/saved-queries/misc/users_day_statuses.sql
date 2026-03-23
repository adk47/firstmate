/*
id: users_day_statuses
title: Users Day Statuses
athena_id: 98735dad-3711-4eb8-b253-7ef3243bc56a
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select id as user_id,
		email,
		subscriptionstatus AS user_status,
		CAST(createdat AS TIMESTAMP) AS user_create_date,
		CAST(trialexpiredat AS TIMESTAMP) AS trial_expired_date,
		SEQUENCE(
			DATE(createdatdate),
			DATE(NOW()),
			INTERVAL '1' DAY
		) AS dates,
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
			),
			COALESCE(
				IF(
					appledata is NULL,
					NULL,
					array [ CAST(json_extract(appledata, '$') AS json) ]
				),
				array [ ]
			),
			COALESCE(
				IF(
					googledata is NULL,
					NULL,
					array [ CAST(json_extract(googledata, '$') AS json) ]
				),
				array [ ]
			),
			COALESCE(
				IF(
					stripedata is NULL,
					NULL,
					array [ CAST(json_extract(stripedata, '$') AS json) ]
				),
				array [ ]
			),
			COALESCE(
				IF(
					paypaldata is NULL,
					NULL,
					array [ CAST(json_extract(paypaldata, '$') AS json) ]
				),
				array [ ]
			)
		) AS prev_subscriptions
	from "production-musomvp"."public_users"
),
_sub AS (
	select user_id,
		user_status,
		case
			when CAST(json_extract(sub, '$.subscriptionId') AS VARCHAR) LIKE 'sub_%' THEN 'stripe'
			when CAST(json_extract(sub, '$.subscriptionId') AS VARCHAR) LIKE 'I-%' THEN 'paypal'
			when TRY_CAST(json_extract(sub, '$.subscriptionId') AS BIGINT) IS NOT NULL THEN 'apple' else 'google'
		END as service,
		UPPER(
			CAST(
				json_extract(sub, '$.subscriptionStatus') AS VARCHAR
			)
		) AS subscription_status,
		UPPER(
			CAST(
				json_extract(sub, '$.subscriptionStatusChangeNote') AS VARCHAR
			)
		) AS status_change_note,
		from_unixtime(
			CAST(
				json_extract(sub, '$.subscriptionCreated') AS BIGINT
			) / 1000
		) AS subscription_created,
		from_unixtime(
			CAST(
				json_extract(sub, '$.subscriptionStart') AS BIGINT
			) / 1000
		) AS subscription_start,
		from_unixtime(
			CAST(json_extract(sub, '$.subscriptionEnd') AS BIGINT) / 1000
		) AS subscription_end,
		CAST(
			from_iso8601_timestamp(
				CAST(json_extract(sub, '$.archivedAt') AS VARCHAR)
			) AS TIMESTAMP
		) AS archived_at,
		CAST(json_extract(sub, '$.subscriptionId') AS VARCHAR) AS subscription_id,
		sub
	from usr
		CROSS JOIN UNNEST(prev_subscriptions) AS s(sub)
),
_usr_sub as (
	select user_id,
		subscription_id,
		service,
		LEAST(
			COALESCE(subscription_created, subscription_start),
			COALESCE(subscription_start, subscription_created)
		) AS subscription_created,
		GREATEST(
			COALESCE(subscription_created, subscription_start),
			COALESCE(subscription_start, subscription_created)
		) AS subscription_start,
		COALESCE(
			CAST(subscription_end AS TIMESTAMP),
			CAST(archived_at AS TIMESTAMP),
			-- for old paypal and stripe users archived_at was not set
			CAST(
				GREATEST(
					COALESCE(subscription_created, subscription_start),
					COALESCE(subscription_start, subscription_created)
				) AS TIMESTAMP
			) + interval '30' day
		) AS subscription_end,
		COALESCE(archived_at, subscription_end, DATE(NOW())) AS archived_at,
		CASE
			WHEN (
				service = 'google'
				AND (
					subscription_status IN ('SUBSCRIPTION_STATE_ACTIVE')
					AND status_change_note = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
				)
			)
			OR (
				service = 'apple'
				AND (
					subscription_status = 'DID_RENEW'
					OR (
						subscription_status = 'SUBSCRIBED'
						and status_change_note = 'RESUBSCRIBE'
					)
				)
			)
			OR (
				service IN ('stripe', 'paypal')
				AND (subscription_status IN ('ACTIVE'))
			)
			OR (
				service = 'paypal'
				AND (subscription_status IN ('APPROVED'))
			) THEN 'PRO'
			WHEN (
				service = 'google'
				AND (
					subscription_status IN ('SUBSCRIPTION_STATE_IN_GRACE_PERIOD')
					AND status_change_note = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
				)
			)
			OR (
				service = 'apple'
				AND (
					subscription_status = 'DID_FAIL_TO_RENEW'
					and status_change_note = 'GRACE_PERIOD'
				)
			)
			OR (
				service IN ('stripe')
				AND (
					subscription_status IN ('INCOMPLETE', 'UNPAID')
				)
			)
			OR (
				service IN ('paypal')
				AND (
					subscription_status IN ('APPROVAL_PENDING')
				)
			) THEN 'PENDING'
			WHEN (
				service = 'google'
				AND subscription_status IN ('SUBSCRIPTION_STATE_CANCELED')
				AND status_change_note = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
			)
			OR (
				service = 'apple'
				AND (
					subscription_status IN ('REFUND', 'GRACE_PERIOD_EXPIRED')
				)
			)
			OR (
				service IN ('stripe')
				AND subscription_status IN (
					'CANCELED',
					'CANCELLED',
					'PAST_DUE'
				)
			)
			OR (
				service IN ('paypal')
				AND subscription_status IN (
					'CANCELED',
					'CANCELLED',
					'SUSPENDED'
				)
			) THEN 'CANCELLED'
			WHEN (
				service = 'google'
				AND subscription_status IN ('SUBSCRIPTION_STATE_EXPIRED')
				AND status_change_note = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
			)
			OR (
				service = 'apple'
				AND (subscription_status IN ('EXPIRED'))
			)
			OR (
				service IN ('stripe', 'paypal')
				AND subscription_status IN ('INCOMPLETE_EXPIRED', 'EXPIRED')
			) THEN 'EXPIRED'
			WHEN (
				service = 'apple'
				and status_change_note = 'INITIAL_BUY'
			)
			OR (
				service = 'stripe'
				and subscription_status = 'TRIALING'
			) THEN 'TRIAL'
		END AS subscription_status,
		subscription_status AS service_subscription_status,
		status_change_note AS service_status_change_note,
		sub AS subscription_details
	from _sub
),
usr_sub AS (
	select user_id,
		COALESCE(subscription_id, 'N/A') AS subscription_id,
		subscription_start,
		subscription_end,
		ARBITRARY(service) AS service,
		MIN(subscription_created) AS subscription_created,
		MAX(archived_at) AS archived_at,
		MAX_BY(
			subscription_status,
			IF(
				subscription_status IS NULL,
				NULL,
				ROW(
					archived_at,
					CASE
						WHEN subscription_status = 'CANCELLED' THEN 10
						WHEN subscription_status = 'PRO' THEN 9
						WHEN subscription_status IN ('GRACE', 'PENDING') THEN 8
						WHEN subscription_status = 'SUSPENDED' THEN 7
						WHEN subscription_status = 'EXPIRED' THEN 6
						WHEN subscription_status = 'TRIAL' THEN 5 else 0
					END
				)
			)
		) AS subscription_status,
		array_agg(subscription_status) AS subscription_statuses
	FROM _usr_sub
	group by 1,
		2,
		3,
		4
),
usr_day_status AS (
	select usr.user_id,
		date_column,
		ARBITRARY(service) AS service,
		ARBITRARY(usr.email) AS email,
		ARBITRARY(user_status) AS user_status,
		DATE(ARBITRARY(user_create_date)) AS user_create_date,
		DATE(ARBITRARY(trial_expired_date)) AS trial_expired_date,
		MAX_BY(service, archived_at) AS last_service,
		COALESCE(
			IF(
				DATE(date_column) = DATE(NOW())
				or DATE(date_column) > MAX(subscription_end),
				NULLIF(ARBITRARY(user_status), 'CANCELLED')
			),
			MAX_BY(
				subscription_status,
				IF(
					subscription_status IS NULL,
					NULL,
					archived_at
				)
			),
			IF(
				DATE_DIFF(
					'day',
					date_column,
					DATE(ARBITRARY(trial_expired_date))
				) between 1 and 7,
				'TRIAL',
				--ARBITRARY(user_status)
				IF(
					DATE_DIFF(
						'day',
						DATE(ARBITRARY(trial_expired_date)),
						date_column
					) = 0,
					'EXPIRED',
					null
				)
			)
		) AS day_subscription_status
	from usr
		cross join unnest (dates) AS usr_dt(date_column)
		left JOIN usr_sub ON (
			usr.user_id = usr_sub.user_id
			AND date_column BETWEEN DATE(subscription_start) and date(subscription_end)
		) -- 		where service = 'apple'
	group by 1,
		2 -- 	where subscription_start is not null -- 	and subscription_status is not null 
),
final AS (
	select user_id,
		date_column,
		LAST_VALUE(day_subscription_status) IGNORE NULLS OVER(
			partition by user_id
			order by date_column rows between unbounded preceding and current row
		) AS last_status,
		day_subscription_status,
		user_status
	from usr_day_status
)
select date_column,
	last_status,
	count(1) AS num_usr
from final
-- where CAST(DATE(date_column) AS VARCHAR) in ('2022-08-01', '2022-07-01', '2022-06-01')
group by 1,
	2
order by DATE(date_column) desc,
	last_status