/*
id: all_subscriptions
title: All Subscriptions
athena_id: 330a1001-ab5a-46de-99cf-2c24261855d7
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
			GREATEST(
				COALESCE(subscription_created, subscription_start),
				COALESCE(subscription_start, subscription_created)
			)
		) AS subscription_end,
		COALESCE(archived_at, NOW()) AS archived_at,
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
					) -- 	OR (
					-- 		subscription_status = 'DID_CHANGE_RENEWAL_STATUS'
					-- 		and status_change_note = 'AUTO_RENEW_ENABLED'
					-- 	)
					-- 	OR (
					-- 		subscription_status = 'DID_CHANGE_RENEWAL_PREF'
					-- 		and (
					-- 			status_change_note is null
					-- 			or status_change_note IN ('UPGRADE', 'DOWNGRADE')
					-- 		)
					-- 	)
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
				service IN ('stripe', 'paypal')
				AND (
					subscription_status IN ('PAST_DUE', 'APPROVAL_PENDING')
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
				service IN ('stripe', 'paypal')
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
				AND subscription_status IN ('INCOMPLETE_EXPIRED')
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
				archived_at
			)
		) AS subscription_status,
		MAX_BY(
			service_subscription_status,
			IF(
				service_subscription_status IS NULL,
				NULL,
				archived_at
			)
		) AS service_subscription_status,
		MAX_BY(
			service_status_change_note,
			IF(
				service_status_change_note IS NULL,
				NULL,
				archived_at
			)
		) AS service_status_change_note,
		array_agg(subscription_status) AS subscription_statuses,
		array_agg(service_subscription_status) AS service_subscription_statuses,
		array_agg(service_status_change_note) AS service_status_change_notes
	FROM _usr_sub
	group by 1,
		2,
		3,
		4
),
final AS (
	select user_id,
		usr.email,
		user_status,
		usr_sub.*
	from usr_sub
		JOIN usr using(user_id) -- 	where subscription_start is not null -- 	and subscription_status is not null 
)
select *
from final
where 1 = 1 -- 	and user_id = 32667 -- 	and subscription_status is null
	and service = 'apple'
	and DATE(subscription_start) > date('2022-07-01')
order by coalesce(subscription_end, subscription_start) desc