/*
id: songstats_export
title: SongStats Export
athena_id: d4e4dbab-0815-4295-87c6-396197f5a0da
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select id as user_id,
		email,
		NULLIF(COALESCE(appledata, googledata), '') is NULL AS is_boomer,
		fullname AS name,
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
			)
		) AS prev_subscriptions
	from "production-musomvp"."public_users"
),
usr_sub AS (
	with _sub AS (
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
	usr_sub as (
		select user_id,
			service,
			subscription_created,
			subscription_start AS subscription_start,
			COALESCE(
				archived_at,
				CAST(subscription_end AS TIMESTAMP),
				subscription_start
			) AS subscription_end,
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
						OR (
							subscription_status = 'DID_CHANGE_RENEWAL_STATUS'
							and status_change_note = 'AUTO_RENEW_ENABLED'
						)
						OR (
							subscription_status = 'DID_CHANGE_RENEWAL_PREF'
							and (
								status_change_note is null
								or status_change_note IN ('UPGRADE', 'DOWNGRADE')
							)
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
				) THEN 'PAID'
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
				) THEN 'GRACE'
				WHEN (
					service = 'google'
					AND subscription_status IN (
						'SUBSCRIPTION_STATE_CANCELED',
						'SUBSCRIPTION_STATE_EXPIRED'
					)
					AND status_change_note = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
				)
				OR (
					service = 'apple'
					AND (
						(
							subscription_status = 'DID_CHANGE_RENEWAL_STATUS'
							and status_change_note = 'AUTO_RENEW_DISABLED'
						)
						or subscription_status IN ('EXPIRED', 'GRACE_PERIOD_EXPIRED', 'REFUND')
					)
				)
				OR (
					service IN ('stripe', 'paypal')
					AND subscription_status IN (
						'CANCELED',
						'CANCELLED',
						'SUSPENDED',
						'INCOMPLETE_EXPIRED'
					)
				) THEN 'CANCELLED'
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
	)
	select user_id,
		date_column,
		MAX_BY(subscription_status, subscription_end) AS subscription_status
	from usr_sub
		CROSS JOIN UNNEST(
			SEQUENCE(
				DATE(subscription_start),
				DATE(subscription_end),
				INTERVAL '1' DAY
			)
		) AS sub_dates(date_column)
	where subscription_start is not null
		and subscription_status is not null
	group by 1,
		2
),
usr_trans as (
	with usr_trans AS (
		select user_id,
			service,
			CAST(transactiondate AS TIMESTAMP) AS transaction_date,
			period_start,
			period_end,
			is_trial,
			case
				when is_trial then 0
				when plan in ('muso_individual_proplus_monthly') then 39.99
				when plan in ('muso_individual_pro_monthly') then 9.99
				when service = 'stripe' then amount / 100 else amount
			end AS amount,
			COALESCE(plan, 'boomer') AS plan,
			transactionid AS transaction_id
		from (
				select userid as user_id,
					service,
					transactionid,
					CAST(
						json_extract(paymentdetails, '$.amount') AS DOUBLE
					) AS amount,
					CAST(
						json_extract(paymentdetails, '$.currency') AS VARCHAR
					) AS currency,
					CAST(
						json_extract(paymentdetails, '$.plan') AS VARCHAR
					) AS plan,
					transactiondate,
					DATE_DIFF('day', DATE("periodstart"), DATE("periodend")) <= 9 AS is_trial,
					DATE(periodstart) AS period_start,
					DATE(periodend) AS period_end
				from "production-musomvp"."public_payment_history"
				where transactionstatus = 'succeeded'
			)
	)
	select user_id,
		date(transaction_date) AS date_column,
		ARRAY_AGG(DISTINCT transaction_id) AS transaction_ids,
		MAX(transaction_date) AS last_transaction_date,
		SUM(amount) AS total_payment
	from usr_trans
	group by 1,
		2
),
usr_seats AS (
	select userid AS user_id,
		count(1) AS total_seats_num,
		count_if(
			status = 'active'
			AND deletedat is NULL
		) AS paid_seats_num,
		filter(
			ARRAY_AGG(
				DISTINCT IF(
					status = 'active'
					AND deletedat is NULL,
					seatid
				)
			),
			e->e IS NOT NULL
		) AS profile_ids
	from "production-musomvp"."public_discovery_seats"
	GROUP BY 1
),
_prof_tracks AS (
	select distinct profile_id,
		track_id
	from (
			SELECT profileid as profile_id,
				MAX_BY(
					SPLIT(substr(tracksids, 2, LENGTH(tracksids) -2), ','),
					date
				) as track_ids
			FROM "production-musomvp"."public_profile_analytics_stats_history"
			group by 1
		)
		CROSS JOIN UNNEST(track_ids) AS t(track_id)
),
usr_tracks AS (
	select user_id,
		count(distinct(track_id)) as num_tracks
	FROM usr_seats AS s
		JOIN _prof_tracks AS t ON (array_position(profile_ids, profile_id) > 0)
	group by 1
),
final AS (
	select user_id,
		ARBITRARY(usr.email) AS email,
		ARBITRARY(usr.name) AS name,
		ARBITRARY(is_boomer) AS is_boomer,
		MAX_BY(subscription_status, date_column) AS last_subscription_status,
		MAX_BY(user_status, date_column) AS last_user_status,
		MAX_BY(paid_seats_num, date_column) AS last_seats_num,
		MAX_BY(num_tracks, date_column) AS last_tracks_num,
		MAX(last_transaction_date) AS last_transaction_date,
		SUM(total_payment) AS total_payment
	from usr_trans
		FULL OUTER JOIN usr_sub USING(user_id, date_column)
		JOIN usr USING(user_id)
		LEFT JOIN usr_seats USING(user_id)
		LEFT JOIN usr_tracks USING(user_id)
	WHERE DATE(date_column) between DATE('2022-08-01') and DATE('2022-08-31')
	group by 1
)
select name,
	COALESCE(
		CASE
			WHEN last_subscription_status IN ('PAID', 'GRACE') THEN 'PRO' ELSE last_subscription_status
		END,
		last_user_status
	) AS subscription_status,
	case
		when COALESCE(last_subscription_status, last_user_status) LIKE '%TRIAL%' then 0
		WHEN total_payment > 0 then total_payment
		WHEN COALESCE(last_subscription_status, last_user_status) IN ('PAID', 'PRO') then (GREATEST(COALESCE(last_seats_num, 0), 1) -1) * 6.99 + 9.99 else 0
	end AS amount,
	last_transaction_date,
	last_seats_num,
	last_tracks_num,
	email
from final