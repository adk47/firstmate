/*
id: songstatsv2
title: SongStatsV2
athena_id: 3f375890-2011-465b-ad57-38121a17815a
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
			),
			COALESCE(
				array [ CAST(json_extract(appledata, '$') AS json) ],
				array [ ]
			),
			COALESCE(
				array [ CAST(json_extract(googledata, '$') AS json) ],
				array [ ]
			),
			COALESCE(
				array [ CAST(json_extract(stripedata, '$') AS json) ],
				array [ ]
			),
			COALESCE(
				array [ CAST(json_extract(paypaldata, '$') AS json) ],
				array [ ]
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
							WHEN subscription_status IN ('CANCELLED', 'SUSPENDED') THEN 10
							WHEN subscription_status = 'PRO' THEN 9
							WHEN subscription_status = 'PENDING' THEN 8
							WHEN subscription_status = 'EXPIRED' THEN 7
							WHEN subscription_status = 'TRIAL' THEN 6 else 0
						END
					)
				)
			) AS subscription_status,
			array_agg(subscription_status) AS subscription_statuses
		FROM _usr_sub
		where subscription_start is not null
		group by 1,
			2,
			3,
			4
	),
	usr_day_status AS (
		select usr.user_id,
			date_column,
			ARBITRARY(usr.email) AS email,
			ARBITRARY(user_status) AS user_status,
			DATE(ARBITRARY(user_create_date)) AS user_create_date,
			DATE(ARBITRARY(trial_expired_date)) AS trial_expired_date,
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
					) between 0 and 6,
					'TRIAL',
					IF(
						DATE_DIFF(
							'day',
							DATE(ARBITRARY(trial_expired_date)),
							date_column
						) = 1,
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
			)
		group by 1,
			2
	)
	select user_id,
		date_column,
		LAST_VALUE(day_subscription_status) IGNORE NULLS OVER(
			partition by user_id
			order by date_column rows between unbounded preceding and current row
		) AS subscription_status
	from usr_day_status
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
		MAX(IF(is_trial, 0, amount)) AS total_payment
	from usr_trans
	group by 1,
		2
),
usr_seats AS (
	select userid AS user_id,
		count(1) AS total_seats_num,
		filter(
			ARRAY_AGG(DISTINCT seatid),
			e->e IS NOT NULL
		) AS profile_ids
	from "production-musomvp"."public_discovery_seats"
	WHERE status = 'active'
		and (createdat < '2022-06-01')
		and (
			deletedat IS NULL
			or deletedat >= '2022-06-01'
		)
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
merged AS (
	select user_id,
		ARBITRARY(usr.email) AS email,
		ARBITRARY(usr.name) AS name,
		ARBITRARY(is_boomer) AS is_boomer,
		MAX_BY(
			subscription_status,
			IF(subscription_status is null, null, date_column)
		) AS last_subscription_status,
		MAX_BY(user_status, date_column) AS last_user_status,
		COALESCE(MAX_BY(total_seats_num, date_column), 0) AS last_seats_num,
		COALESCE(MAX_BY(num_tracks, date_column), 0) AS last_tracks_num,
		MAX(last_transaction_date) AS last_transaction_date,
		SUM(total_payment) AS total_payment,
		MAX(total_payment) AS last_payment,
		SUM(cardinality(transaction_ids)) AS cnt_payments
	from usr_trans
		FULL OUTER JOIN usr_sub USING(user_id, date_column)
		JOIN usr USING(user_id)
		LEFT JOIN usr_seats USING(user_id)
		LEFT JOIN usr_tracks USING(user_id)
	WHERE DATE(date_column) between DATE('2022-05-01') and DATE('2022-05-31')
		and (
			user_create_date is null
			OR user_create_date < DATE('2022-06-01')
		)
	group by 1
),
final AS (
	select name,
		COALESCE(
			last_subscription_status,
			last_user_status
		) AS subscription_status,
		case
			when COALESCE(last_subscription_status, last_user_status) LIKE '%CANCEL%' then last_payment
			WHEN COALESCE(last_subscription_status, last_user_status) IN ('PRO') THEN IF(
				is_boomer,
				IF(
					COALESCE(last_payment, 9.99) > 9.99,
					ceiling((last_payment -9.99) / 6.99) * 6.99 + 9.99,
					9.99
				),
				COALESCE(last_payment, 9.99)
			) else 0
		end AS reported_amount,
		is_boomer,
		last_tracks_num,
		total_payment,
		cnt_payments,
		last_transaction_date,
		last_seats_num,
		case
			when COALESCE(last_subscription_status, last_user_status) LIKE '%TRIAL%' then 0
			when COALESCE(last_subscription_status, last_user_status) LIKE '%CANCEL%' then total_payment
			WHEN COALESCE(last_subscription_status, last_user_status) IN ('PAID', 'PRO')
			and NOT is_boomer then IF(last_seats_num > 1, 39.99, 9.99)
			WHEN COALESCE(last_subscription_status, last_user_status) IN ('PAID', 'PRO')
			and is_boomer then (GREATEST(COALESCE(last_seats_num, 0), 1) -1) * 6.99 + 9.99 else 0
		end AS seats_payment,
		email,
		last_user_status
	from merged
)
select name,
	IF(
		subscription_status = 'CANCELLED',
		'PRO',
		subscription_status
	) AS subscription_status,
	CAST(
		IF(
			is_boomer,
			GREATEST(CEIL((reported_amount - 9.99) / 6.99), 0),
			IF(reported_amount > 9.99, 5, 1)
		) AS INT
	) AS boomer_discovery_seats,
	if(
		is_boomer,
		IF(
			subscription_status IN ('PRO', 'CANCELLED'),
			'old_pro',
			'old_trial'
		),
		IF(
			subscription_status IN ('PRO', 'CANCELLED'),
			IF(reported_amount > 9.99, 'PRO_PLUS', 'PRO'),
			'TRIAL'
		)
	) AS user_payment_status,
	reported_amount AS payment,
	last_tracks_num AS num_tracks
from final
WHERE subscription_status IN ('PRO', 'TRIAL')
	OR subscription_status = 'CANCELLED'
	and reported_amount > 0